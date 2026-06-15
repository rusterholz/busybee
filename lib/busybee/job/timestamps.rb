# frozen_string_literal: true

module Busybee
  class Job
    # Lifecycle timestamps for hook instrumentation. Each timestamp is a
    # monotonic + UTC pair, recorded via stamp!(name). Per-moment readers
    # take a kind arg (:utc or :monotonic; default :utc); bulk accessors
    # monotonic and utc return hashes of the stamped values for each kind.
    # Held privately by Job; per-moment readers are delegated up.
    class Timestamps
      NAMES = %i[
        activated_at execution_started_at perform_started_at
        perform_finished_at resolved_at executed_at
      ].freeze

      def stamp!(name)
        unless NAMES.include?(name)
          raise ArgumentError, "Unknown timestamp: #{name}. Expected one of: #{NAMES.join(', ')}"
        end

        instance_variable_set(:"@#{name}_monotonic", Process.clock_gettime(Process::CLOCK_MONOTONIC))
        instance_variable_set(:"@#{name}_utc", Time.now.utc)
        self
      end

      NAMES.each do |name|
        define_method(name) do |type = :utc|
          case type
          when :utc then instance_variable_get(:"@#{name}_utc")
          when :monotonic then instance_variable_get(:"@#{name}_monotonic")
          else
            raise ArgumentError, "Unknown timestamp type: #{type.inspect}. Expected :utc or :monotonic."
          end
        end
      end

      def monotonic
        hash_of(:monotonic)
      end

      def utc
        hash_of(:utc)
      end

      def context_tags
        {}
      end

      def logging_context
        utc
      end

      def perform_duration_ms
        compute_ms_between(:perform_started_at, :perform_finished_at)
      end

      def resolution_duration_ms
        compute_ms_between(:execution_started_at, :resolved_at)
      end

      def execution_duration_ms
        compute_ms_between(:execution_started_at, :executed_at)
      end

      def buffer_latency_ms
        compute_ms_between(:activated_at, :execution_started_at)
      end

      def total_duration_ms
        compute_ms_between(:activated_at, :resolved_at)
      end

      def post_resolution_ms
        compute_ms_between(:resolved_at, :executed_at)
      end

      def setup_duration_ms
        compute_ms_between(:execution_started_at, :perform_started_at)
      end

      private

      def compute_ms_between(from, to)
        from_value = public_send(from, :monotonic)
        to_value = public_send(to, :monotonic)
        return nil unless from_value && to_value

        ((to_value - from_value) * 1000).round(1)
      end

      def hash_of(type)
        NAMES.each_with_object({}) do |name, h|
          value = public_send(name, type)
          h[name] = value unless value.nil?
        end
      end
    end
  end
end
