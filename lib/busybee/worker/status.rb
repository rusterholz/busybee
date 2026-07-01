# frozen_string_literal: true

require "active_support/core_ext/module/delegation"

module Busybee
  class Worker
    # A frozen, point-in-time snapshot of a worker run. Handed to worker hooks
    # as the |worker| carrier and stamped into job context for job-hook
    # visibility. Deliberately NOT the live Runner: it carries no
    # run!/stop!/kill! control surface, so a hook cannot steer the runner from
    # inside an observation. Built fresh at each firing moment; a nil reader
    # means "not yet known" (e.g. stop_duration_ms before the drain, or
    # reason/error before the run ends).
    class Status
      attr_reader :worker_class, :worker_mode, :timestamps,
                  :total_job_count, :failed_job_count, :backpressure_count,
                  :current_buffer_size, :peak_buffer_size,
                  :reason, :error

      # The worker class's declared contract object; the DSL-contract readers
      # below forward through it.
      delegate :configuration, to: :worker_class

      # Declared DSL contract — the "what's on the menu" surface for external
      # registries — read through the configuration.
      delegate :job_type, :inputs, :outputs, :description, to: :configuration

      # Lifecycle timing — read off the snapshotted Worker::Timestamps; the
      # per-moment readers forward their (type = :utc) kind argument.
      delegate :started_at, :stop_requested_at, :stopping_at, :shutdown_at,
               :stop_duration_ms, :stop_latency_ms, :lifetime_s, to: :timestamps

      # Container identity (Busybee.worker_name) — not the per-job worker.
      delegate :worker_name, to: :Busybee

      def initialize(worker_class:, worker_mode:, timestamps:, # rubocop:disable Metrics/ParameterLists
                     total_job_count: 0, failed_job_count: 0, backpressure_count: 0,
                     current_buffer_size: nil, peak_buffer_size: nil,
                     reason: nil, error: nil)
        @worker_class = worker_class
        @worker_mode = worker_mode
        @timestamps = timestamps.dup.freeze
        @total_job_count = total_job_count
        @failed_job_count = failed_job_count
        @backpressure_count = backpressure_count
        @current_buffer_size = current_buffer_size
        @peak_buffer_size = peak_buffer_size
        @reason = reason
        @error = error
        freeze
      end

      # The recorded error's class, or nil. Returns the Class (like worker_class),
      # so a hook filter matches it by Class, name string, or Regexp uniformly.
      def error_class
        error&.class
      end

      # The recorded error's message, or nil.
      def error_message
        error&.message
      end
    end
  end
end
