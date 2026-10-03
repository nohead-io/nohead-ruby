# frozen_string_literal: true

require "time"

module Nohead
  # What the SDK returns for the API's resources: read fields as methods
  # (`record.data`) or with `[]` (`record["data"]`), nested objects included.
  # Fields named like Ruby's own methods (`method`, `hash`...) need `[]`.
  # Timestamps (`*_at`) are Times. Unknown fields are kept: the API adds
  # fields without notice.
  class NoheadObject
    ISO_TIME = /\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:\d{2})\z/

    def self.wrap(value, key = nil)
      case value
      when Hash then new(value)
      when Array then value.map { |item| wrap(item) }
      when String
        key.to_s.end_with?("_at") && value.match?(ISO_TIME) ? Time.iso8601(value) : value
      else value
      end
    end

    def initialize(values)
      @values = values.to_h { |key, value| [key.to_s, value] }
    end

    def [](key)
      key = key.to_s
      self.class.wrap(@values[key], key)
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
