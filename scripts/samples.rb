# frozen_string_literal: true

# Writes samples.json: for each API-key operation, a Ruby code sample that
# calls it, from the calls in test/calls.rb (which the contract test checks
# against the contract). The Nohead API repository puts them in the docs
# site's API reference (x-codeSamples).
#
#   rake samples

require "json"
require "prism"
require "stringio"

root = File.expand_path("..", __dir__)
$LOAD_PATH.unshift File.join(root, "lib")
require "nohead"
require_relative "../test/fake_transport"
require_relative "../test/calls"

# What a list's items are called in the block, by operation.
ITEMS = { "record_revisions" => "revision", "schema_changes" => "change",
          "webhook_deliveries" => "delivery", "audit_events" => "event",
          "collections_search" => "record", "projects_search" => "record" }.freeze
ROUTES = Nohead::OPERATIONS.map do |id, (method, path)|
  [id, method, Regexp.new("\\A#{path.gsub(/\{\w+\}/, '[^/]+')}\\z")]
end

def item_name(operation)
  ITEMS.find { |prefix, _| operation.start_with?(prefix) }&.last || operation.split("_").first.delete_suffix("s")
end

# The source of each lambda's body in Calls::EVERY_CALL, in order.
source = File.read(File.join(root, "test/calls.rb"), encoding: "UTF-8")
array = Prism.parse(source).value.breadth_first_search do |node|
  node.is_a?(Prism::ConstantWriteNode) && node.name == :EVERY_CALL
end.value
array = array.receiver if array.is_a?(Prism::CallNode) # .freeze
bodies = array.elements.map { |lambda_node| lambda_node.body.slice }

samples = {}
Calls::EVERY_CALL.zip(bodies).each do |call, body|
  transport = FakeTransport.new([Calls.method(:reply)])
  nohead = Nohead::Client.new(api_key: "sk_live_sample", base_url: "https://api.test",
                              project_id: "prj_sample", transport: transport)
  result = call.call(nohead)
  request = transport.requests.find { |r| r.uri.host == "api.test" }
  operation = ROUTES.find { |_, method, pattern| method == request.method && request.path.match?(pattern) }&.first
  raise "No operation for #{body}" unless operation

  requires = body.include?("StringIO") ? %(require "nohead"\nrequire "stringio") : %(require "nohead")
  statement = if result.is_a?(Nohead::Page)
                name = item_name(operation)
                "#{body}.each do |#{name}|\n  puts #{name}\nend"
              else
                "result = #{body}"
              end
  samples[operation] ||= "#{requires}\n\nnohead = Nohead::Client.new\n\n#{statement}\n"
end

File.write(File.join(root, "samples.json"), "#{JSON.pretty_generate(samples.sort.to_h)}\n")
puts "samples.json: #{samples.size} operations"
