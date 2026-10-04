# frozen_string_literal: true

# Every API-key operation in the contract must be reachable from the SDK's
# public methods, every request must match its operation (method, path and
# declared query parameters), and every declared query parameter must be sent
# by some call. A new operation or query parameter in openapi.json fails this
# test until a method takes it (and a call in test/calls.rb or below passes it).
require_relative "test_helper"
require_relative "calls"

class ContractTest < Minitest::Test
  include Helpers

  SPEC = JSON.parse(File.read(File.expand_path("../openapi.json", __dir__), encoding: "UTF-8"))

  ROUTES = Nohead::OPERATIONS.map do |id, (method, path)|
    item = SPEC["paths"][path]
    params = (item.fetch("parameters", []) + item[method.downcase].fetch("parameters", [])).filter_map do |parameter|
      parameter = SPEC["components"]["parameters"][parameter["$ref"].split("/").last] if parameter["$ref"]
      parameter["name"] if parameter["in"] == "query"
    end
    [id, method, Regexp.new("\\A#{path.gsub(/\{\w+\}/, '[^/]+')}\\z"), params]
  end

  def operation_of(request)
    ROUTES.find { |_, method, pattern, _| method == request.method && request.path.match?(pattern) } or
      flunk "No operation for #{request.method} #{request.path}"
  end

  # Query parameters an API key has no use for: it always acts on its own project.
  NOT_FOR_API_KEYS = { "feature_flags_list" => %w[organization_id project_id] }.freeze

  # Calls that pass the query parameters the samples in test/calls.rb leave out.
  EVERY_PARAMETER = [
    ->(nohead) { nohead.records.list("posts", cursor: "cur_x") },
    ->(nohead) { nohead.records.revisions.list("rec_01J9ZQ3F8X", limit: 5, cursor: "cur_x") },
    ->(nohead) { nohead.records.search("posts", "hello", limit: 5, cursor: "cur_x") },
    ->(nohead) { nohead.search("hello", limit: 5, cursor: "cur_x") },
    ->(nohead) { nohead.collections.list(limit: 5, cursor: "cur_x") },
    ->(nohead) { nohead.collections.schema_changes.list("posts", limit: 5, cursor: "cur_x") },
    ->(nohead) { nohead.fields.list("posts", limit: 5, cursor: "cur_x") },
    ->(nohead) { nohead.migrations.list("posts", limit: 5, cursor: "cur_x") },
    ->(nohead) { nohead.assets.list(content_type: ["image/*"], limit: 5, cursor: "cur_x") },
    ->(nohead) { nohead.assets.image_url("ast_01J9ZQ3F8X", height: 100, fit: "cover", quality: 80) },
    ->(nohead) { nohead.webhooks.list(limit: 5, cursor: "cur_x") },
    ->(nohead) { nohead.webhooks.deliveries.list("wh_01J9ZQ3F8X", limit: 5, cursor: "cur_x") },
    ->(nohead) { nohead.audit_events.list(limit: 5, cursor: "cur_x") }
  ].freeze

  def test_the_client_covers_the_contract
    nohead, transport = client([Calls.method(:reply)])
    (Calls::EVERY_CALL + EVERY_PARAMETER).each { |call| call.call(nohead) }

    api = transport.requests.select { |request| request.uri.host == "api.test" }
    sent = Hash.new { |hash, id| hash[id] = [] }
    api.each do |request|
      id, _, _, params = operation_of(request)
      keys = request.params.keys.map { |key| key.split("[").first }.uniq
      assert_empty keys - params, "#{id} sends undeclared query parameters"
      sent[id] |= keys
    end
    assert_empty Nohead::OPERATIONS.keys - sent.keys, "operations without an SDK method"
    unsent = ROUTES.to_h { |id, _, _, params| [id, params - sent[id] - NOT_FOR_API_KEYS.fetch(id, [])] }
    assert_empty unsent.reject { |_, params| params.empty? }, "query parameters no call sends"
  end
end
