# frozen_string_literal: true

module Busybee
  class Worker
    # Lifecycle timing for a single worker run. The four runner moments
    # (started → stop_requested → stopping → shutdown) as monotonic + UTC
    # pairs, recorded via stamp!(name). Per-moment readers take a kind arg
    # (:utc default for logging, :monotonic for math). Mirrors Job::Timestamps.
    #
    # The runner holds the live, accumulating instance and stamps it across
    # run!; Worker::Status snapshots a dup of it. Named under Worker (not
    # Runner) so the worker-hook carrier and its timing read as one family.
    class Timestamps
      NAMES = %i[started_at stop_requested_at stopping_at shutdown_at].freeze

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

      # Graceful-drain time: stopping (T2) → shutdown (T3).
      def stop_duration_ms
        ms_between(:stopping_at, :shutdown_at)
      end

      # Stop-acknowledge latency: stop_requested (T1) → stopping (T2). The
      # SIGTERM→drain delay, meaningful even when the run loop is wedged.
      def stop_latency_ms
        ms_between(:stop_requested_at, :stopping_at)
      end

      # Total run lifetime in seconds: started (T0) → shutdown (T3).
      def lifetime_s
        ms_between(:started_at, :shutdown_at)&.then { |ms| (ms / 1000.0).round(1) }
      end

      private

      def ms_between(from, to)
        from_value = public_send(from, :monotonic)
        to_value = public_send(to, :monotonic)
        return nil unless from_value && to_value

        ((to_value - from_value) * 1000).round(1)
      end
    end
  end
end
