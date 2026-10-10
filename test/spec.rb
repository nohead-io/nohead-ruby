# frozen_string_literal: true

require "json"

# The contract (openapi.json) as the tests read it: which operation a request
# is, and an example of any schema, which the mock replies in test/calls.rb are
# made of.
module Spec
  CONTRACT = JSON.parse(File.read(File.expand_path("../openapi.json", __dir__), encoding: "UTF-8"))

  # `schema_at` is where `schema` is in the contract.
  Parameter = Struct.new(:name, :schema, :schema_at)
  Body = Struct.new(:schema, :schema_at)
  # `body` is nil for operations without one; `status` and `response` are the
  # first success response's.
  Route = Struct.new(:id, :method, :pattern, :query, :body, :body_required, :status, :response) # rubocop:disable Lint/StructNewOverride

  # A JSON pointer into the contract.
  def self.pointer(*parts) = "#/#{parts.map { |part| part.gsub('~', '~0').gsub('/', '~1') }.join('/')}"

  # The value at a pointer, and where it is, following a $ref there.
  def self.at(path)
    value = path.delete_prefix("#/").split("/").reduce(CONTRACT) do |node, part|
      part = part.gsub("~1", "/").gsub("~0", "~")
      node.is_a?(Array) ? node[Integer(part)] : node.fetch(part)
    end
    value.is_a?(Hash) && value["$ref"] ? at(value["$ref"]) : [path, value]
  end

  def self.query(owner, path)
    owner.fetch("parameters", []).each_index.filter_map do |index|
      where, parameter = at("#{path}/parameters/#{index}")
      Parameter.new(parameter["name"], parameter["schema"], "#{where}/schema") if parameter["in"] == "query"
    end
  end

  def self.json(path)
    where = "#{at(path).first}/content/application~1json/schema"
    Body.new(at(where).last, where)
  end

  ROUTES = Nohead::OPERATIONS.map do |id, (method, path)|
    item = CONTRACT["paths"][path]
    operation = item[method.downcase]
    operation_at = pointer("paths", path, method.downcase)
    status = operation["responses"].keys.find { |code| code.start_with?("2") }
    Route.new(id, method, Regexp.new("\\A#{path.gsub(/\{\w+\}/, '[^/]+')}\\z"),
              query(item, pointer("paths", path)) + query(operation, operation_at),
              operation["requestBody"] && json("#{operation_at}/requestBody"),
              operation.dig("requestBody", "required") == true, Integer(status),
              json("#{operation_at}/responses/#{status}"))
  end

  def self.route_of(method, path)
    ROUTES.find { |route| route.method == method && path.match?(route.pattern) } or
      raise "No operation for #{method} #{path}"
  end

  STRINGS = { "date-time" => "2026-10-02T12:00:00Z", "date" => "2026-10-02" }.freeze

  # A value that matches `schema`: its example, constant, first enum value or
  # default, else one built from its type, with every property (the first
  # non-null type, the first of oneOf and anyOf).
  def self.example(schema)
    return example(at(schema["$ref"]).last) if schema["$ref"]
    return schema["examples"].first if schema["examples"]
    return schema["const"] if schema.key?("const")
    return schema["enum"].first if schema["enum"]
    return schema["default"] if schema.key?("default")
    return schema["allOf"].map { |part| example(part) }.reduce({}, :merge) if schema["allOf"]
    return example((schema["oneOf"] || schema["anyOf"]).first) if schema["oneOf"] || schema["anyOf"]

    example_of_type(schema)
  end

  def self.example_of_type(schema)
    types = Array(schema["type"])
    case types.find { |type| type != "null" } || types.first
    when "object" then schema.fetch("properties", {}).transform_values { |property| example(property) }
    when "array" then Array.new([schema.fetch("minItems", 1), 1].max) { example(schema.fetch("items", {})) }
    when "string" then STRINGS.fetch(schema["format"], "string")
    when "integer", "number" then schema.fetch("minimum", 1)
    when "boolean" then false
    when "null" then nil
    else {}
    end
  end
end
