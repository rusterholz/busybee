# frozen_string_literal: true

require "active_support/core_ext/hash/indifferent_access"
require "active_support/core_ext/object/json"
require "active_support/core_ext/string/inflections"
require "json"

require "busybee/error"

module Busybee
  # Centralized JSON serialization and deserialization for GRPC communication.
  #
  # Provides consistent handling of Ruby objects to/from JSON strings,
  # with proper as_json support for serialization and indifferent access
  # with method-style accessors for deserialization.
  module Serialization
    # Serialize a Ruby object to JSON string for GRPC.
    #
    # Calls as_json first so objects with custom serialization
    # (like ActiveRecord models, Time, etc.) work correctly.
    #
    # @param obj [Object] The object to serialize (typically a Hash)
    # @return [String] JSON string
    def self.to_json(obj)
      JSON.generate(obj.as_json)
    end

    # Deserialize a JSON string from GRPC to a frozen Ruby hash.
    #
    # Returns a frozen HashWithIndifferentAccess with method-style access
    # (via HashAccess module). Nested hashes and arrays are also frozen
    # and support method-style access.
    #
    # @param json_string [String, nil] The JSON string to parse
    # @return [ActiveSupport::HashWithIndifferentAccess] frozen hash with method access
    # @raise [Busybee::InvalidJobJson] if JSON is invalid
    def self.from_json(json_string)
      if json_string.nil? || json_string.empty?
        return ActiveSupport::HashWithIndifferentAccess.new.extend(HashAccess).freeze
      end

      parsed = JSON.parse(json_string)
      deep_freeze_and_extend(parsed.with_indifferent_access)
    rescue JSON::ParserError => e
      raise Busybee::InvalidJobJson, "Failed to parse JSON: #{e.message}", e.backtrace, cause: e
    end

    # Recursively freeze and extend hashes with HashAccess.
    #
    # @param obj [Object] The object to process
    # @return [Object] The frozen, extended object
    def self.deep_freeze_and_extend(obj)
      case obj
      when Hash
        obj.extend(HashAccess)
        obj.each_value { |value| deep_freeze_and_extend(value) }
        obj.freeze
      when Array
        obj.each { |element| deep_freeze_and_extend(element) }
        obj.freeze
      else
        obj.freeze if obj.respond_to?(:freeze)
        obj
      end
    end

    private_class_method :deep_freeze_and_extend

    # Module that adds method-style access to hashes with camelCase to snake_case conversion.
    #
    # Allows accessing hash keys as methods:
    #   hash.order_id       # looks for "order_id" or "orderId"
    #   hash.customer_name  # looks for "customer_name" or "customerName"
    #
    # Recursively applied to nested hashes.
    module HashAccess
      def method_missing(method_name, *args, **kwargs, &block)
        return super if args.any? || kwargs.any? || block

        # Convert snake_case method name to potential camelCase keys
        snake_key = method_name.to_s
        camel_key = snake_key.camelize(:lower)

        if key?(snake_key)
          self[snake_key]
        elsif key?(camel_key)
          self[camel_key]
        else
          super
        end
      end

      def respond_to_missing?(method_name, include_private = false)
        snake_key = method_name.to_s
        camel_key = snake_key.camelize(:lower)
        key?(snake_key) || key?(camel_key) || super
      end
    end
  end
end
