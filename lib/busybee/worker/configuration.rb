# frozen_string_literal: true

require "active_support/core_ext/string/inflections"

module Busybee
  class Worker
    # Stores all DSL-declared metadata for a Worker subclass.
    # Lazily instantiated per worker class via Worker.configuration.
    class Configuration # rubocop:disable Metrics/ClassLength
      VALID_TYPES = %w[string integer decimal boolean datetime duration uuid null].freeze
      VALID_SOURCES = %i[variable header].freeze
      VALID_RUNNER_MODES = %i[polling streaming hybrid].freeze
      VALID_POLLING_KWARGS = %i[max_jobs request_timeout].freeze
      VALID_STREAMING_KWARGS = %i[queue queue_throttle].freeze

      # Represents a declared input (from variable, header, or both).
      Input = Struct.new(:name, :source, :required, :type, :description, :default,
                         :accessor_name, :define_accessor, keyword_init: true)

      # Represents a declared output returned from perform.
      Output = Struct.new(:name, :required, :type, :description, keyword_init: true)

      attr_accessor :description
      attr_reader :inputs, :outputs, :runner_mode, :polling_config, :streaming_config,
                  :job_timeout, :backoff, :complete_job_on_success, :fail_job_on_error, :shutdown_on

      def initialize(worker_class)
        @worker_class = worker_class
        @job_type = nil
        @description = nil
        @inputs = []
        @outputs = []
        @runner_mode = nil
        @polling_config = {}
        @streaming_config = {}
        @job_timeout = nil
        @backoff = nil
        @complete_job_on_success = true
        @fail_job_on_error = true
        @shutdown_on = []
      end

      def job_type
        @job_type || derive_default_job_type
      end

      def job_type=(value)
        @job_type = value.to_s
      end

      def runner_mode=(value)
        sym = value.to_sym
        unless VALID_RUNNER_MODES.include?(sym)
          raise InvalidWorkerDefinition,
                "Invalid runner mode #{value.inspect}. Valid: #{VALID_RUNNER_MODES.map(&:inspect).join(', ')}"
        end

        @runner_mode = sym
      end

      def polling_config=(kwargs)
        unknown = kwargs.keys - VALID_POLLING_KWARGS
        if unknown.any?
          raise InvalidWorkerDefinition,
                "Unknown polling config: #{unknown.map(&:inspect).join(', ')}. " \
                "Valid: #{VALID_POLLING_KWARGS.map(&:inspect).join(', ')}"
        end

        @polling_config = kwargs
      end

      def streaming_config=(kwargs)
        unknown = kwargs.keys - VALID_STREAMING_KWARGS
        if unknown.any?
          raise InvalidWorkerDefinition,
                "Unknown streaming config: #{unknown.map(&:inspect).join(', ')}. " \
                "Valid: #{VALID_STREAMING_KWARGS.map(&:inspect).join(', ')}"
        end

        validate_queue_option!(kwargs) if kwargs.key?(:queue)
        validate_queue_throttle!(kwargs) if kwargs.key?(:queue_throttle)

        @streaming_config = kwargs
      end

      def job_timeout=(value)
        validate_duration!(:job_timeout, value)
        @job_timeout = value
      end

      def backoff=(value)
        validate_duration!(:backoff, value)
        @backoff = value
      end

      def complete_job_on_success=(value)
        unless [true, false].include?(value)
          raise InvalidWorkerDefinition, "`complete_job_on_success` requires a boolean, got #{value.inspect}"
        end

        @complete_job_on_success = value
      end

      def fail_job_on_error=(value)
        unless [true, false].include?(value)
          raise InvalidWorkerDefinition, "`fail_job_on_error` requires a boolean, got #{value.inspect}"
        end

        @fail_job_on_error = value
      end

      def add_shutdown_on(*exception_classes)
        exception_classes.each do |klass|
          unless klass.is_a?(Class) && klass <= Exception
            raise InvalidWorkerDefinition,
                  "`shutdown_on` expects exception classes, got #{klass.inspect}"
          end
        end

        @shutdown_on |= exception_classes
      end

      def add_input(input)
        validate_name!(input.name, "input")
        validate_source!(input)
        validate_type!(input.name, input.type, "input") if input.type
        validate_accessor_options!(input)
        validate_unique_input!(input.name)

        @inputs << input
      end

      def add_output(output)
        validate_name!(output.name, "output")
        validate_type!(output.name, output.type, "output") if output.type
        validate_unique_output!(output.name)

        @outputs << output
      end

      # Resolved queue throttle for the streaming pump thread.
      # Returns false (no throttling), 0 (minimal throttle), or a positive Numeric (ms).
      def queue_throttle
        streaming_config.fetch(:queue_throttle, Busybee.default_queue_throttle)
      end

      # Whether this worker uses a pump thread + queue for streaming.
      # Default: true. Set to false via `streaming queue: false` for inline stream processing.
      def queue_enabled?
        streaming_config.fetch(:queue, Busybee::Defaults::DEFAULT_STREAMING_QUEUE)
      end

      # Returns resolved polling options for client.with_each_job, merging
      # DSL overrides with gem-level defaults.
      def polling_options
        {
          max_jobs: polling_config[:max_jobs] || Busybee::Defaults::DEFAULT_MAX_JOBS,
          request_timeout: polling_config[:request_timeout] || Busybee.default_job_request_timeout,
          job_timeout: job_timeout || Busybee.default_job_lock_timeout
        }
      end

      # Returns resolved streaming options for client.open_job_stream.
      def streaming_options
        { job_timeout: job_timeout || Busybee.default_job_lock_timeout }
      end

      def to_h
        {
          job_type: job_type,
          description: description,
          inputs: inputs.map(&:to_h),
          outputs: outputs.map(&:to_h),
          runner_mode: runner_mode,
          polling_config: polling_config,
          streaming_config: streaming_config,
          job_timeout: job_timeout,
          backoff: backoff,
          complete_job_on_success: complete_job_on_success,
          fail_job_on_error: fail_job_on_error,
          shutdown_on: shutdown_on
        }
      end

      private

      def derive_default_job_type
        class_name = @worker_class.name
        return "worker" if class_name.nil?

        last_segment = class_name.split("::").last
        last_segment = last_segment.delete_suffix("Worker") if last_segment != "Worker"
        last_segment.underscore
      end

      def validate_name!(name, kind)
        raise InvalidWorkerDefinition, "Name is required for all #{kind}s" if name.nil? || name.to_s.strip.empty?
      end

      def validate_source!(input)
        sources = Array(input.source)
        raise InvalidWorkerDefinition, "`source:` is required for input :#{input.name}" if sources.empty?

        invalid = sources - VALID_SOURCES
        unless invalid.empty?
          raise InvalidWorkerDefinition,
                "Invalid source #{invalid.map(&:inspect).join(', ')} for input :#{input.name}. " \
                "Valid: #{VALID_SOURCES.map(&:inspect).join(', ')}"
        end

        # Deduplicate sources (e.g., [:variable, :variable] → [:variable])
        input.source = sources.uniq
      end

      def validate_type!(name, type, kind)
        return if VALID_TYPES.include?(type.to_s)

        raise InvalidWorkerDefinition,
              "Invalid type #{type.inspect} for #{kind} :#{name}. " \
              "Valid: #{VALID_TYPES.join(', ')}"
      end

      def validate_accessor_options!(input)
        return unless !input.define_accessor && input.accessor_name

        raise InvalidWorkerDefinition,
              "`define_accessor: false` and `accessor_name:` are mutually exclusive on input :#{input.name} " \
              "— no accessor will be defined, so naming it is meaningless"
      end

      def validate_unique_input!(name)
        return unless @inputs.any? { |i| i.name == name }

        raise InvalidWorkerDefinition, "Input :#{name} is already declared"
      end

      def validate_unique_output!(name)
        return unless @outputs.any? { |o| o.name == name }

        raise InvalidWorkerDefinition, "Output :#{name} is already declared"
      end

      def validate_queue_option!(kwargs)
        return if [true, false].include?(kwargs[:queue])

        raise InvalidWorkerDefinition, "`queue:` requires a boolean, got #{kwargs[:queue].inspect}"
      end

      def validate_queue_throttle!(kwargs)
        # Coerce: true → 0 ("enable at minimal setting"), nil → false ("no throttling")
        kwargs[:queue_throttle] = 0 if kwargs[:queue_throttle] == true
        kwargs[:queue_throttle] = false if kwargs[:queue_throttle].nil?

        value = kwargs[:queue_throttle]
        return if value == false
        return if value.is_a?(Numeric) && value >= 0

        raise InvalidWorkerDefinition,
              "`queue_throttle:` must be a non-negative Numeric, got #{value.inspect}"
      end

      def validate_duration!(attr, value)
        return if value.is_a?(Integer)
        return if defined?(ActiveSupport::Duration) && value.is_a?(ActiveSupport::Duration)

        raise InvalidWorkerDefinition,
              "`#{attr}` accepts Integer (milliseconds) or ActiveSupport::Duration, got #{value.class}"
      end
    end
  end
end
