# frozen_string_literal: true

require "time"

module Nohead
  # What the SDK returns for the API's resources: read fields as methods
  # (`record.data`) or with `[]` (`record["data"]`), nested objects included.
  # Fields named like Ruby's own methods (`method`, `hash`...) need `[]`.
  # Timestamps (the contract's: `created_at`, `purge_after`, `at`...) are
  # Times; a record's field values (`record.data`) are left as they come,
  # but for the resources `expand` embeds in them. Unknown fields are kept:
  # the API adds fields without notice.
  class NoheadObject
    ISO_TIME = /\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:\d{2})\z/

    # `fields`: the value is (in) a record's field values, whose keys are
    # api_keys, so no timestamps.
    def self.wrap(value, key = nil, fields: false)
      case value
      when Hash then new(value, fields: fields && !value.key?("object"))
      when Array then value.map { |item| wrap(item, fields: fields) }
      when String
        !fields && TIMESTAMPS.include?(key.to_s) && value.match?(ISO_TIME) ? Time.iso8601(value) : value
      else value
      end
    end

    def initialize(values, fields: false)
      @values = values.to_h { |key, value| [key.to_s, value] }
      @fields = fields
    end

    def [](key)
      key = key.to_s
      fields = @fields || (key == "data" && RECORD_DATA_OBJECTS.include?(@values["object"]))
      self.class.wrap(@values[key], key, fields: fields)
    end

    def key?(key) = @values.key?(key.to_s)
    def keys = @values.keys

    def dig(key, *rest)
      value = self[key]
      rest.empty? || value.nil? ? value : value.dig(*rest)
    end

    # The fields as a plain Hash with string keys (raw values).
    def to_h = @values

    def ==(other) = other.is_a?(NoheadObject) && other.to_h == to_h

    def respond_to_missing?(name, include_private = false)
      @values.key?(name.to_s) || super
    end

    def method_missing(name, *args)
      key = name.to_s
      return super unless args.empty? && @values.key?(key)

      self[key]
    end

    def inspect
      label = @values["object"] ? "#{@values['object']} " : ""
      "#<Nohead::NoheadObject #{label}#{@values.inspect}>"
    end
    alias to_s inspect
  end
end
