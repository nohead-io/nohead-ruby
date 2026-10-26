# frozen_string_literal: true

require "json"
require "securerandom"
require "time"
require "uri"

module Nohead
  # A client for the Nohead API, authenticated with a project API key.
  #
  #   nohead = Nohead::Client.new # NOHEAD_API_KEY
  #   nohead.records.list("posts").each { |post| puts post.data["title"] }
  class Client
    DEFAULT_BASE_URL = "https://api.nohead.io"

    # Each warning is given once per process, as the other SDKs do: an app
    # that builds a client per request would otherwise warn on every one.
    WARNED = Set.new
    WARNED_LOCK = Mutex.new
    private_constant :WARNED_LOCK

    def self.first_warning?(key) = WARNED_LOCK.synchronize { !WARNED.add?(key).nil? }
    RETRYABLE_STATUSES = [429, 500, 502, 503, 504].freeze
    MAX_RETRY_AFTER = 60

    attr_reader :records, :revisions, :drafts, :collections, :fields, :migrations, :assets, :webhooks,
                :audit_events, :feature_flags, :me, :health

    # The key's project ID, looked up once, and once at a time, for a client
    # and its copies (with_options).
    class ProjectLookup
      def initialize(id)
        @id = id
        @lock = Mutex.new
      end

      def get
        @id || @lock.synchronize { @id ||= yield }
      end
    end
    private_constant :ProjectLookup

    # api_key::     A project API key ("nohead_sk_...", or "nohead_pk_..." when
    #               published-only). Defaults to NOHEAD_API_KEY.
    # base_url::    Defaults to NOHEAD_API_URL, else https://api.nohead.io.
    # project_id::  The key's project. Looked up once with GET /v1/me when omitted.
    # max_retries:: Retries of failed requests (see the README, "Retries").
    # timeout::     Seconds per attempt.
    # headers::     Headers added to every request.
    # warnings::    Warn about deprecated operations and plan usage (once each).
    #
    # An empty string is the same as leaving an option out.
    def initialize(api_key: nil, base_url: nil, project_id: nil, max_retries: 2, timeout: 60,
                   headers: {}, warnings: true, transport: Transport.new)
      @api_key = present(api_key) || present(ENV.fetch("NOHEAD_API_KEY", nil)) or
        raise Error, "Missing API key: pass api_key or set NOHEAD_API_KEY"
      @base_url = checked_base_url(present(base_url) || present(ENV.fetch("NOHEAD_API_URL", nil)) ||
                                   DEFAULT_BASE_URL)
      @project = ProjectLookup.new(present(project_id))
      @max_retries = max_retries
      @timeout = timeout
      @headers = merge_headers({}, headers)
      @warnings = warnings
      @transport = transport

      @records = Resources::Records.new(self)
      @revisions = Resources::RevisionsById.new(self)
      @drafts = Resources::Drafts.new(self)
      @collections = Resources::Collections.new(self)
      @fields = Resources::Fields.new(self)
      @migrations = Resources::Migrations.new(self)
      @assets = Resources::Assets.new(self)
      @webhooks = Resources::Webhooks.new(self)
      @audit_events = Resources::AuditEvents.new(self)
      @feature_flags = Resources::FeatureFlags.new(self)
      @me = Resources::Me.new(self)
      @health = Resources::Health.new(self)
    end

    # Full-text search across the key's project (or some of its collections),
    # most relevant first, through the first 1,000 hits. `filter` takes
    # `published_at` ({ published_at: { exists: true } } for published
    # records), as records.list does. `collections` wins over a `collection`
    # filter.
    def search(query, collections: nil, filter: nil, limit: nil, cursor: nil)
      filter = filter.to_h.transform_keys(&:to_sym)
      filter = filter.merge(collection: { in: collections }) unless collections.nil?
      paginate("projects_search", query: { q: query, filter: filter, limit: limit, cursor: cursor })
    end

    # The API key's project, from GET /v1/me the first time. Threads that
    # need it at the same time wait for one lookup.
    def project_id
      @project.get do
        me = request("me_get")
        me.api_key or raise Error, "The credentials are not a project API key"
        me.api_key.project_id
      end
    end

    # Sends one operation (as listed in Nohead::OPERATIONS) and returns its
    # result. The resources call this; it is public for operations the SDK
    # does not wrap yet.
    def request(operation, path: {}, query: {}, body: nil, idempotency_key: nil,
                change_note: nil, if_match: nil)
      NoheadObject.wrap(exchange(operation, path: path, query: query, body: body, idempotency_key: idempotency_key,
                                            change_note: change_note, if_match: if_match).first)
    end

    # A list operation as a Page that fetches the following pages as needed.
    def paginate(operation, path: {}, query: {})
      params = query.dup
      cursor = params.delete(:cursor)
      fetch = lambda do |next_cursor|
        list, status = exchange(operation, path: path, query: params.merge(cursor: next_cursor))
        unless list.is_a?(Hash) && list["data"].is_a?(Array) && list["meta"].is_a?(Hash)
          raise Error, "The API's response could not be read (HTTP #{status})"
        end

        Page.new(NoheadObject.wrap(list["data"]), NoheadObject.wrap(list["meta"]), &fetch)
      end
      fetch.call(cursor)
    end

    # Sends a file to a presigned storage URL (no API credentials).
    def put_upload(url, method, headers, source)
      retries = source.replayable? ? @max_retries : 0
      attempt = 0
      loop do
        begin
          response = @transport.call(method, url,
                                     headers.merge("Content-Length" => source.byte_size.to_s),
                                     source.io, @timeout)
          return response unless RETRYABLE_STATUSES.include?(response.status) && attempt < retries
        rescue ConnectionError
          raise if attempt >= retries
        end
        pause(backoff(attempt))
        attempt += 1
        source.rewind
      end
    end

    def inspect = "#<Nohead::Client #{@base_url}>"

    private

    # The parsed body of a 2xx response, and its status.
    def exchange(operation, path: {}, query: {}, body: nil, idempotency_key: nil,
                 change_note: nil, if_match: nil)
      method, template = OPERATIONS.fetch(operation)
      url = build_url(template, path) + query_string(query)
      headers = request_headers(method, body, idempotency_key, change_note, if_match)
      payload = body.nil? ? nil : JSON.generate(json_ready(body))
      attempt = 0
      loop do
        begin
          response = @transport.call(method, url, headers, payload, @timeout)
        rescue ConnectionError
          raise if attempt >= @max_retries

          pause(backoff(attempt))
          attempt += 1
          next
        end

        warn_about(operation, response.headers)
        parsed = parse(response)
        return [parsed, response.status] if response.status.between?(200, 299)

        error = Nohead.api_error(response.status, parsed, response.headers)
        delay = retry_delay(error, attempt)
        raise error if delay.nil?

        pause(delay)
        attempt += 1
      end
    end

    def build_url(template, values)
      values = values.transform_keys(&:to_s)
      # A value the template doesn't take is a method out of step with its operation.
      unknown = values.keys - template.scan(/\{(\w+)\}/).flatten
      raise ArgumentError, "#{unknown.join(', ')} is not a path parameter of #{template}" if unknown.any?

      values["project_id"] ||= project_id if template.include?("{project_id}")
      path = template.gsub(/\{(\w+)\}/) do
        name = Regexp.last_match(1)
        value = values[name]
        raise Error, "Missing #{name}" if value.nil? || value.to_s.empty?
        # Encoded, "." and ".." would still be resolved as the path's own segments.
        raise Error, %(Invalid #{name}: "#{value}") if %w[. ..].include?(value.to_s)

        URI.encode_uri_component(value.to_s)
      end
      @base_url + path
    end

    # Query parameters as the API reads them: hashes become key[sub]=...
    # (filter[price][lt]=50), arrays are comma-separated (expand=author,tags)
    # with \, for a comma inside a value and \\ for a backslash, times are
    # ISO 8601. nil values are left out.
    def query_string(params)
      pairs = []
      add = lambda do |key, value|
        case value
        when nil then nil
        when Hash then value.each { |name, inner| add.call("#{key}[#{name}]", inner) }
        when Array
          items = value.compact.map { |item| scalar(item).gsub(/[\\,]/) { |char| "\\#{char}" } }
          pairs << [key, items.join(",")] unless items.empty?
        else pairs << [key, scalar(value)]
        end
      end
      params.each { |key, value| add.call(key.to_s, value) }
      pairs.empty? ? "" : "?#{URI.encode_www_form(pairs)}"
    end

    def scalar(value)
      case value
      when Time, DateTime then value.to_time.utc.iso8601(3)
      when Date then value.iso8601
      else value.to_s
      end
    end

    def json_ready(value)
      case value
      when Hash then value.to_h { |key, inner| [key.to_s, json_ready(inner)] }
      when Array then value.map { |item| json_ready(item) }
      when Time, DateTime, Date then scalar(value)
      when Symbol then value.to_s
      else value
      end
    end

    # The SDK's headers, then the client's `headers:`, then the ones request
    # options set, which win.
    def request_headers(method, body, idempotency_key, change_note, if_match)
      headers = merge_headers({
                                "Accept" => "application/json",
                                "Authorization" => "Bearer #{@api_key}",
                                "Nohead-Client" => "sdk-ruby/#{VERSION}",
                                "User-Agent" => "nohead-ruby/#{VERSION} ruby/#{RUBY_VERSION}"
                              }, @headers)
      options = {}
      options["Content-Type"] = "application/json" unless body.nil?
      options["Idempotency-Key"] = present(idempotency_key) || SecureRandom.uuid unless method == "GET"
      options["If-Match"] = %("#{revision_of(if_match)}") unless if_match.nil?
      # Percent-encoded UTF-8, as encodeURIComponent: header values are bytes
      # (the API decodes it). Notes in other encodings are converted first.
      if present(change_note)
        note = change_note.to_s.encode(Encoding::UTF_8, invalid: :replace, undef: :replace)
        options["Nohead-Change-Note"] = URI.encode_uri_component(note)
      end
      merge_headers(headers, options)
    end

    # `extra` over `headers`, matching names without regard to case, so each
    # name is sent once.
    def merge_headers(headers, extra)
      extra.each_with_object(headers.dup) do |(name, value), merged|
        name = name.to_s
        merged.delete_if { |key, _| key.casecmp?(name) }
        merged[name] = value.to_s
      end
    end

    # A revision number, or a record or draft (anything with a revision, a
    # Hash too).
    def revision_of(if_match)
      revision = if if_match.is_a?(Hash)
                   if_match.key?(:revision) ? if_match[:revision] : if_match["revision"]
                 else
                   if_match.respond_to?(:revision) ? if_match.revision : if_match
                 end
      return revision if revision.is_a?(Integer)

      raise ArgumentError, "if_match takes a revision number, or a record or draft (or { revision: 3 }), " \
                           "not #{if_match.inspect}"
    end

    def checked_base_url(url)
      url = url.to_s.sub(%r{/+\z}, "")
      uri = URI.parse(url)
      return url if %w[http https].include?(uri.scheme&.downcase) && !uri.host.to_s.empty?

      raise Error, "base_url must be an http or https URL"
    rescue URI::InvalidURIError
      raise Error, "base_url must be an http or https URL"
    end

    def parse(response)
      return nil if response.body.nil? || response.body.empty?
      return response.body unless response.headers["content-type"].to_s.include?("json")

      JSON.parse(response.body)
    rescue JSON::ParserError
      response.body
    end

    # Seconds to wait before retrying `error`, or nil to raise it.
    def retry_delay(error, attempt)
      return nil if attempt >= @max_retries

      in_progress = error.status == 409 && error.details.any? { |d| d["code"] == "in_progress" }
      return nil unless in_progress || RETRYABLE_STATUSES.include?(error.status)

      retry_after = Nohead.retry_after_seconds(error.headers)
      return backoff(attempt) if retry_after.nil?

      retry_after <= MAX_RETRY_AFTER ? retry_after : nil
    end

    # Exponential backoff with jitter: about 0.5 s, 1 s, 2 s... up to 8 s.
    def backoff(attempt)
      [0.5 * (2**attempt), 8.0].min * (1 - (rand * 0.25))
    end

    def pause(seconds)
      sleep(seconds) if seconds.positive?
    end

    def warn_about(operation, headers)
      return unless @warnings

      if !headers["deprecation"].to_s.strip.empty? && self.class.first_warning?(operation)
        sunset = headers["sunset"] ? " and will be removed after #{headers['sunset']}" : ""
        link = headers["link"].to_s[/<([^>]+)>/, 1]
        warn "[nohead] #{operation} is deprecated#{sunset}#{". See #{link}" if link}"
      end
      return unless headers["nohead-usage-warning"] && self.class.first_warning?(:usage)

      warn "[nohead] Over a plan limit: #{headers['nohead-usage-warning']}"
    end

    def present(value)
      value.nil? || value.to_s.empty? ? nil : value
    end
  end
end
