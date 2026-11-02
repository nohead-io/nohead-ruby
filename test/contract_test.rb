# frozen_string_literal: true

# Every API-key operation in the contract must be reachable from the SDK's
# public methods, every request must match its operation (method, path,
# declared query parameters and their values, and the JSON body), and every
# declared query parameter must be sent by some call. A new operation or query
# parameter in openapi.json fails this test until a method takes it (and a
# call in test/calls.rb or below passes it). Each call gets the contract's
# examples of its operation's response, one per oneOf variant, and must return
# them. Methods take `if_match`, `change_note` and `rich_text` exactly where
# their operations declare If-Match, Nohead-Change-Note and rich_text, and a
# client's `rich_text:` goes with exactly the operations that declare it.
require_relative "test_helper"
require_relative "calls"

class ContractTest < Minitest::Test
  include Helpers

  def errors(pointer, value) = Contract.errors(pointer, value)

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
    ->(nohead) { nohead.drafts.list("posts", sort: "updated_at", limit: 5, cursor: "cur_x") },
    ->(nohead) { nohead.collections.schema_changes.list("posts", limit: 5, cursor: "cur_x") },
    ->(nohead) { nohead.fields.list("posts", limit: 5, cursor: "cur_x") },
    ->(nohead) { nohead.migrations.list("posts", limit: 5, cursor: "cur_x") },
    ->(nohead) { nohead.assets.list(content_type: "image/*", limit: 5, cursor: "cur_x") },
    ->(nohead) { nohead.assets.list(content_type: %w[image/* application/pdf]) },
    ->(nohead) { nohead.assets.list(q: "hero jpg", kind: "image") },
    ->(nohead) { nohead.assets.list(kind: %w[image video]) },
    ->(nohead) { nohead.webhooks.list(limit: 5, cursor: "cur_x") },
    ->(nohead) { nohead.webhooks.deliveries.list("wh_01J9ZQ3F8X", limit: 5, cursor: "cur_x") },
    ->(nohead) { nohead.webhooks.secrets.list("wh_01J9ZQ3F8X", limit: 5, cursor: "cur_x") },
    ->(nohead) { nohead.audit_events.list(limit: 5, cursor: "cur_x") },
    ->(nohead) { nohead.records.list("posts", rich_text: "html") },
    ->(nohead) { nohead.records.get("rec_01J9ZQ3F8X", rich_text: "markdown") },
    ->(nohead) { nohead.records.create("posts", data: { body: "# Hi" }, rich_text: "markdown") },
    ->(nohead) { nohead.records.update("rec_01J9ZQ3F8X", data: { body: "# Hey" }, rich_text: "markdown") },
    ->(nohead) { nohead.records.delete("rec_01J9ZQ3F8X", rich_text: "html") },
    ->(nohead) { nohead.records.restore("rec_01J9ZQ3F8X", rich_text: "html") },
    ->(nohead) { nohead.records.publish("rec_01J9ZQ3F8X", rich_text: "html") },
    ->(nohead) { nohead.records.unpublish("rec_01J9ZQ3F8X", rich_text: "html") },
    ->(nohead) { nohead.records.drafts("rec_01J9ZQ3F8X", rich_text: "html") },
    ->(nohead) { nohead.records.bulk("posts", action: "publish", record_ids: ["rec_01J9ZQ3F8X"], rich_text: "html") },
    ->(nohead) { nohead.records.search("posts", "hello", rich_text: "html") },
    ->(nohead) { nohead.records.revisions.revert("rec_01J9ZQ3F8X", 1, rich_text: "html") },
    ->(nohead) { nohead.search("hello", rich_text: "html") },
    ->(nohead) { nohead.drafts.create("rec_01J9ZQ3F8X", data: { body: "# Hey" }, rich_text: "markdown") },
    ->(nohead) { nohead.drafts.list("posts", rich_text: "html") },
    ->(nohead) { nohead.drafts.get("drf_01J9ZQ3F8X", rich_text: "html") },
    ->(nohead) { nohead.drafts.update("drf_01J9ZQ3F8X", data: { body: "# Hey" }, rich_text: "document") },
    ->(nohead) { nohead.drafts.discard("drf_01J9ZQ3F8X", rich_text: "html") },
    ->(nohead) { nohead.drafts.merge("drf_01J9ZQ3F8X", rich_text: "html") },
    ->(nohead) { nohead.drafts.schedule("drf_01J9ZQ3F8X", merge_at: Time.utc(2027, 1, 1), rich_text: "html") },
    ->(nohead) { nohead.drafts.unschedule("drf_01J9ZQ3F8X", rich_text: "html") }
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

  def test_the_clients_rich_text_goes_with_the_operations_that_declare_it
    nohead, transport = client([Calls.method(:reply)], rich_text: "markdown")
    Calls::EVERY_CALL.each { |call| call.call(nohead) }
    routes = transport.requests.select { |request| request.uri.host == "api.test" }.map do |request|
      route = Spec.route_of(request.method, request.path)
      expected = route.query.map(&:name).include?("rich_text") ? { "rich_text" => "markdown" } : {}
      assert_equal expected, request.params.slice("rich_text"), route.id
      route.id
    end
    assert_empty Nohead::OPERATIONS.keys - routes
  end

  # Checks a request against its operation (as FakeTransport does with
  # every request), noting the parameters sent.
  def check_request(request, sent)
    route = Spec.route_of(request.method, request.path)
    assert_empty Contract.request_problems(request), route.id
    sent[route.id] |= request.params.keys.map { |key| key.split("[").first }.uniq
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

  # The SDK options that send a header, by header, and a query parameter, by name.
  HEADER_OPTIONS = { "If-Match" => :if_match, "Nohead-Change-Note" => :change_note }.freeze
  QUERY_OPTIONS = { "rich_text" => :rich_text }.freeze
  OPTIONS = (HEADER_OPTIONS.values + QUERY_OPTIONS.values).freeze

  def test_methods_take_the_options_their_operations_declare
    checked = Calls::EVERY_CALL.filter_map do |call|
      nohead, transport = client([Calls.method(:reply)])
      method = outermost_method { call.call(nohead) }
      api = transport.requests.select { |request| request.uri.host == "api.test" }
      next if api.size > 1 # a helper (assets.upload), made of methods checked on their own

      route = Spec.route_of(api.first.method, api.first.path)
      taken = method.parameters.filter_map { |kind, name| name if %i[key keyreq].include?(kind) }
      assert_equal declared_options(route).sort, (taken & OPTIONS).sort, "#{method.owner}##{method.name} (#{route.id})"
      route.id
    end
    assert_empty Nohead::OPERATIONS.keys - checked, "operations whose method is not checked"
  end

  # The SDK options an operation's method must take.
  def declared_options(route)
    HEADER_OPTIONS.filter_map { |header, option| option if route.headers.include?(header) } +
      QUERY_OPTIONS.filter_map { |name, option| option if route.query.map(&:name).include?(name) }
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
