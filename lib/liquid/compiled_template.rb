# frozen_string_literal: true

require 'json'

module Liquid
  # Versioned, data-only serialization for parsed Liquid templates.
  module CompiledTemplate
    FORMAT = "liquid-compiled-template"
    VERSION = 1

    ERROR_MODES = %w[lax warn strict strict2 rigid].freeze
    COMMAND_LOOKUPS = VariableLookup::COMMAND_METHODS

    MAX_PAYLOAD_BYTES = 16 * 1024 * 1024
    MAX_STRING_BYTES = 1024 * 1024
    MAX_PARTIALS = 1000
    MAX_NODES = 100_000
    MAX_DEPTH = Block::MAX_DEPTH
    MAX_INTEGER_ABS = 10**18

    class << self
      def dump(template, **options)
        JSON.generate(export(template, **options))
      end

      def export(template, partials: nil)
        Serializer.new.serialize(template, partials: partials)
      end

      def load(
        payload,
        environment: Environment.default,
        name: nil,
        max_nodes: MAX_NODES,
        max_depth: MAX_DEPTH,
        max_string_bytes: MAX_STRING_BYTES,
        max_partials: MAX_PARTIALS
      )
        Loader.new(
          environment: environment,
          name: name,
          max_nodes: limit_option(max_nodes, MAX_NODES, "max_nodes"),
          max_depth: limit_option(max_depth, MAX_DEPTH, "max_depth"),
          max_string_bytes: limit_option(max_string_bytes, MAX_STRING_BYTES, "max_string_bytes"),
          max_partials: limit_option(max_partials, MAX_PARTIALS, "max_partials"),
        ).load(payload)
      end

      private

      def limit_option(value, maximum, name)
        value = Integer(value)
        raise ArgumentError, "#{name} must be positive" unless value.positive?
        raise ArgumentError, "#{name} cannot exceed #{maximum}" if value > maximum
        value
      end
    end
  end
end

require_relative 'compiled_template/serializer'
require_relative 'compiled_template/loader'
