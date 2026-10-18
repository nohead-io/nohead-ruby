# frozen_string_literal: true

# Every API-key operation in the contract must be reachable from the SDK's
# public methods, every request must match its operation (method, path,
# declared query parameters and their values, and the JSON body), and every
# declared query parameter must be sent by some call. A new operation or query
# parameter in openapi.json fails this test until a method takes it (and a
# call in test/calls.rb or below passes it). Each call gets the contract's
# examples of its operation's response, one per oneOf variant, and must return
# them. Methods take `if_match` and `change_note` exactly where their
# operations declare If-Match and Nohead-Change-Note.
require_relative "test_helper"
require_relative "calls"
require "json_schemer"

class ContractTest < Minitest::Test
  include Helpers

  DOCUMENT = JSONSchemer.openapi(Spec::CONTRACT, format: false)

  # The errors of `value` against the schema at `pointer` in the contract.
  def errors(pointer, value)
    DOCUMENT.ref(pointer.gsub("{", "%7B").gsub("}", "%7D")).validate(value).map { |error| error["error"] }
  end

  # A request's query parameters by name, as their schemas read them:
  # filter[a][b]=v nests, and numbers and booleans are parsed when declared.
  def query_values(request, params)
    types = params.to_h { |param| [param.name, param.schema["type"]] }
    request.params.each_with_object({}) do |(key, value), values|
      name, *path = key.split(/[\[\]]+/).reject(&:empty?)
      if path.any?
        path[0...-1].reduce(values[name] ||= {}) { |node, part| node[part] ||= {} }[path.last] = value
      else
        values[name] = typed(value, types[name])
      end
    end
  end

  def typed(value, type)
    if %w[integer number].include?(type) && value.match?(/\A-?\d+(\.\d+)?\z/)
      value.include?(".") ? Float(value) : Integer(value)
    elsif type == "boolean" && %w[true false].include?(value)
      value == "true"
    else
      value
    end
  end

  # A result as JSON, to compare with the reply it was parsed from.
  def plain(result)
    result.is_a?(Nohead::Page) ? { "data" => result.data.map(&:to_h), "meta" => result.meta.to_h } : result.to_h
  end

  # Calls that pass the query parameters the samples in test/calls.rb leave out.
  EVERY_PARAMETER = [
    ->(nohead) { nohead.records.list("posts", cursor: "cur_x") },
    ->(nohead) { nohead.records.revisions.list("rec_01J9ZQ3F8X", limit: 5, cursor: "cur_x") },
    ->(nohead) { nohead.records.search("posts", "hello", limit: 5, cursor: "cur_x") },
    ->(nohead) { nohead.search("hello", limit: 5, cursor: "cur_x") },
    ->(nohead) { nohead.collections.list(limit: 5, cursor: "cur_x") },
    ->(nohead) { nohead.records.scheduled_changes("posts", sort: "-at", limit: 5, cursor: "cur_x") },
    ->(nohead) { nohead.records.drafts("rec_01J9ZQ3F8X", limit: 5, cursor: "cur_x") },
    lambda { |nohead|
      nohead.drafts.list("posts", record_id: "rec_01J9ZQ3F8X", sort: "updated_at", limit: 5, cursor: "cur_x")
    },
    ->(nohead) { nohead.collections.schema_changes.list("posts", limit: 5, cursor: "cur_x") },
    ->(nohead) { nohead.fields.list("posts", limit: 5, cursor: "cur_x") },
    ->(nohead) { nohead.migrations.list("posts", limit: 5, cursor: "cur_x") },
    ->(nohead) { nohead.assets.list(content_type: ["image/*"], limit: 5, cursor: "cur_x") },
    ->(nohead) { nohead.assets.image_url("ast_01J9ZQ3F8X", height: 100, fit: "cover", quality: 80) },
    ->(nohead) { nohead.webhooks.list(limit: 5, cursor: "cur_x") },
    ->(nohead) { nohead.webhooks.deliveries.list("wh_01J9ZQ3F8X", limit: 5, cursor: "cur_x") },
    ->(nohead) { nohead.webhooks.secrets.list("wh_01J9ZQ3F8X", limit: 5, cursor: "cur_x") },
    ->(nohead) { nohead.audit_events.list(limit: 5, cursor: "cur_x") }
  ].freeze

  def test_the_client_covers_the_contract
    nohead, transport = client([Calls.method(:reply)])
    sent = Hash.new { |hash, id| hash[id] = [] }
    (Calls::EVERY_CALL + EVERY_PARAMETER).each do |call|
      start = transport.requests.size
      result = call.call(nohead)
      api = transport.requests[start..].select { |request| request.uri.host == "api.test" }
      api.each { |request| check_request(request, sent) }
      check_result(api.last, result)
    end
    assert_empty Nohead::OPERATIONS.keys - sent.keys, "operations without an SDK method"
    unsent = Spec::ROUTES.to_h do |route|
      [route.id, route.query.map(&:name) - sent[route.id]]
    end
    assert_empty unsent.reject { |_, params| params.empty? }, "query parameters no call sends"
  end

  # Checks a request against its operation, noting the parameters sent.
  def check_request(request, sent)
    route = Spec.route_of(request.method, request.path)
    keys = request.params.keys.map { |key| key.split("[").first }.uniq
    assert_empty keys - route.query.map(&:name), "#{route.id} sends undeclared query parameters"
    check_query_values(route, request)
    if request.body
      refute_nil route.body, "#{route.id} takes no body"
      assert_empty errors(route.body.schema_at, request.json), "#{route.id} body"
    else
      refute route.body_required, "#{route.id} needs a body"
    end
    sent[route.id] |= keys
  end

  def check_query_values(route, request)
    values = query_values(request, route.query)
    route.query.select { |param| values.key?(param.name) }.each do |param|
      assert_empty errors(param.schema_at, values[param.name]), "#{route.id} #{param.name}"
    end
  end

  # The method returns the response its last request got.
  def check_result(request, result)
    route = Spec.route_of(request.method, request.path)
    assert_equal Calls.example_reply(route, request), plain(result), "#{route.id} returns its response"
  end

  def test_every_success_response_has_valid_examples
    Spec::ROUTES.each do |route|
      request = FakeTransport::Request.new(route.method, "https://api.test/", {}, nil)
      assert_empty errors(route.response.schema_at, Calls.example_reply(route, request)), route.id
      Spec.examples(route.response.schema).each do |example|
        assert_empty errors(route.response.schema_at, example), "#{route.id}: #{JSON.generate(example)}"
      end
    end
  end

  # Each call returns every variant of its response, not only the first.
  def test_every_variant_of_a_response_comes_back
    Calls::EVERY_CALL.each do |call|
      route = calls_route(call)
      Spec.examples(route.response.schema).each do |example|
        example = JSON.parse(JSON.generate(example))
        reply = lambda do |request|
          next Calls.reply(request) unless request.uri.host == "api.test" &&
                                           Spec.route_of(request.method, request.path) == route

          Nohead::Response.new(route.status, { "content-type" => "application/json" }, JSON.generate(example))
        end
        nohead, = client([reply])
        assert_equal example, plain(call.call(nohead)), route.id
      end
    end
  end

  # The SDK options that send a header, by header.
  HEADER_OPTIONS = { "If-Match" => :if_match, "Nohead-Change-Note" => :change_note }.freeze

  def test_methods_take_the_headers_their_operations_declare
    checked = Calls::EVERY_CALL.filter_map do |call|
      nohead, transport = client([Calls.method(:reply)])
      method = outermost_method { call.call(nohead) }
      api = transport.requests.select { |request| request.uri.host == "api.test" }
      next if api.size > 1 # a helper (assets.upload), made of methods checked on their own

      route = Spec.route_of(api.first.method, api.first.path)
      declared = HEADER_OPTIONS.filter_map { |header, option| option if route.headers.include?(header) }
      taken = method.parameters.filter_map { |kind, name| name if %i[key keyreq].include?(kind) }
      assert_equal declared.sort, (taken & HEADER_OPTIONS.values).sort, "#{method.owner}##{method.name} (#{route.id})"
      route.id
    end
    assert_empty Nohead::OPERATIONS.keys - checked, "operations whose method is not checked"
  end

  # The operation the last request of a call is.
  def calls_route(call)
    nohead, transport = client([Calls.method(:reply)])
    call.call(nohead)
    request = transport.requests.reverse.find { |sent| sent.uri.host == "api.test" }
    Spec.route_of(request.method, request.path)
  end

  # The SDK method a call calls (the first one it enters).
  def outermost_method(&)
    called = nil
    trace = TracePoint.new(:call) do |point|
      next if called || !(point.self.is_a?(Nohead::Resources::Resource) || point.self.is_a?(Nohead::Client))

      called = point.self.method(point.method_id)
    end
    trace.enable(&)
    called
  end
end
