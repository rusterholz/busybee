# frozen_string_literal: true

module Busybee
  module Hooks
    # Mixin that restricts modification of keys present at extend-time.
    # New keys (annotations) can still be added freely.
    module RestrictedAccess
      def self.extended(base)
        base.instance_variable_set(:@restricted_keys, base.keys.to_set(&:to_s).freeze)
      end

      def []=(key, value)
        check_restricted!(key)
        super
      end

      def store(key, value)
        check_restricted!(key)
        super
      end

      def update(other_hash)
        other_hash.each_key { |key| check_restricted!(key) } if @restricted_keys
        super
      end
      alias merge! update

      private

      def check_restricted!(key)
        raise FrozenError, "can't modify restricted key: #{key}" if @restricted_keys&.include?(key.to_s)
      end
    end
  end
end
