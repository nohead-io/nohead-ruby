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
    RETRYABLE_STATUSES = [429, 500, 502, 503, 504].freeze
    MAX_RETRY_AFTER = 60

    attr_reader :records, :collections, :fields, :migrations, :assets, :webhooks,
                :audit_events, :feature_flags, :me, :health

    # api_key::     A project API key ("sk_live_..."). Defaults to NOHEAD_API_KEY.
    # base_url::    Defaults to NOHEAD_API_URL, else https://api.nohead.io.
    # project_id::  The key's project. Looked up once with GET /v1/me when omitted.
    # max_retries:: Retries of failed requests (see the README, "Retries").
    # timeout::     Seconds per attempt.
    # headers::     Headers added to every request.
    # warnings::    Warn about deprecated operations and plan usage (once each).
    def initialize(api_key: nil, base_url: nil, project_id: nil, max_retries: 2, timeout: 60,
                   headers: {}, warnings: true, transport: Transport.new)
      @api_key = present(api_key) || present(ENV.fetch("NOHEAD_API_KEY", nil)) or
        raise Error, "Missing API key: pass api_key or set NOHEAD_API_KEY"
      @base_url = (present(base_url) || present(ENV.fetch("NOHEAD_API_URL", nil)) ||
                   DEFAULT_BASE_URL).chomp("/")
      @project_id = project_id
      @max_retries = max_retries
      @timeout = timeout
      @headers = headers.to_h { |key, value| [key.to_s, value.to_s] }
      @warnings = warnings
      @transport = transport
      @warned = {}

      @records = Resources::Records.new(self)
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
    # most relevant first, through the first 1,000 hits.
    def search(query, collections: nil, status: nil, limit: nil, cursor: nil)
      paginate("projects_search", query: {
                 q: query, collections: collections, filter: { status: status }, limit: limit,
                 cursor: cursor
               })
    end

    # The API key's project, from GET /v1/me the first time.
    def project_id
      @project_id ||= begin
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
      NoheadObject.wrap(send_request(operation, path: path, query: query, body: body,
                                                idempotency_key: idempotency_key,
                                                change_note: change_note, if_match: if_match))
    end

    # A list operation as a Page that fetches the following pages as needed.
    def paginate(operation, path: {}, query: {})
      params = query.dup
      cursor = params.delete(:cursor)
      fetch = lambda do |next_cursor|
        list = send_request(operation, path: path, query: params.merge(cursor: next_cursor))
        Page.new(NoheadObject.wrap(list.fetch("data")), NoheadObject.wrap(list.fetch("meta")),
                 &fetch)
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

    def send_request(operation, path: {}, query: {}, body: nil, idempotency_key: nil,
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
        return parsed if response.status.between?(200, 299)

        error = Nohead.api_error(response.status, parsed, response.headers)
        delay = retry_delay(error, attempt)
        raise error if delay.nil?

        pause(delay)
        attempt += 1
      end
    end

    def build_url(template, values)
      values = values.transform_keys(&:to_s)
      values["project_id"] ||= project_id if template.include?("{project_id}")
      path = template.gsub(/\{(\w+)\}/) do
        value = values[Regexp.last_match(1)]
        raise Error, "Missing #{Regexp.last_match(1)}" if value.nil? || value.to_s.empty?

        URI.encode_www_form_component(value.to_s).gsub("+", "%20")
      end
      @base_url + path
    end

    # Query parameters as the API reads them: hashes become key[sub]=...
    # (filter[status]=published), arrays are comma-separated (expand=author,tags),
    # times are ISO 8601. nil values are left out.
    def query_string(params)
      pairs = []
      add = lambda do |key, value|
        case value
        when nil then nil
        when Hash then value.each { |name, inner| add.call("#{key}[#{name}]", inner) }
        when Array
          items = value.compact.map { |item| scalar(item) }
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
      when Time, DateTime then value.to_time.utc.iso8601(3)
      when Date then value.iso8601
      when Symbol then value.to_s
      else value
      end
    end

    def request_headers(method, body, idempotency_key, change_note, if_match)
      headers = {
        "Accept" => "application/json",
        "Authorization" => "Bearer #{@api_key}",
        "Nohead-Client" => "sdk-ruby/#{VERSION}",
        "User-Agent" => "nohead-ruby/#{VERSION} ruby/#{RUBY_VERSION}"
      }.merge(@headers)
      headers["Content-Type"] = "application/json" unless body.nil?
      headers["Idempotency-Key"] = idempotency_key || SecureRandom.uuid unless method == "GET"
      unless if_match.nil?
        revision = if_match.respond_to?(:revision) ? if_match.revision : if_match
        headers["If-Match"] = %("#{revision}")
      end
      headers["Nohead-Change-Note"] = change_note if change_note
      headers
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

      if headers["deprecation"] && !@warned[operation]
        @warned[operation] = true
        sunset = headers["sunset"] ? " and will be removed after #{headers['sunset']}" : ""
        link = headers["link"].to_s[/<([^>]+)>/, 1]
        warn "[nohead] #{operation} is deprecated#{sunset}#{". See #{link}" if link}"
      end
      return unless headers["nohead-usage-warning"] && !@warned[:usage]

      @warned[:usage] = true
      warn "[nohead] Over a plan limit: #{headers['nohead-usage-warning']}"
    end

    def present(value)
      value.nil? || value.to_s.empty? ? nil : value
    end
  end
end
