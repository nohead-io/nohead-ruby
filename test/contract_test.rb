# frozen_string_literal: true

# Every API-key operation in the contract must be reachable from the SDK's
# public methods, and every request must match its operation: method, path and
# declared query parameters. A new operation in openapi.json fails this test
# until a method (and a call in test/calls.rb) covers it.
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

  def test_the_client_covers_the_contract
    nohead, transport = client([Calls.method(:reply)])
    Calls::EVERY_CALL.each { |call| call.call(nohead) }

    api = transport.requests.select { |request| request.uri.host == "api.test" }
    api.each do |request|
      id, _, _, params = operation_of(request)
      sent = request.params.keys.map { |key| key.split("[").first }.uniq
      assert_empty sent - params, "#{id} sends undeclared query parameters"
    end
    covered = api.map { |request| operation_of(request).first }
    assert_empty Nohead::OPERATIONS.keys - covered, "operations without an SDK method"
  end
end
