# frozen_string_literal: true

require "active_support/core_ext/string/inflections"
require "busybee/durations"

module Busybee
  class Worker
    # Stores all DSL-declared metadata for a Worker subclass.
    # Lazily instantiated per worker class via Worker.configuration.
    class Configuration # rubocop:disable Metrics/ClassLength
      VALID_TYPES = %w[string integer decimal boolean datetime duration uuid null].freeze
      VALID_SOURCES = %i[variable header].freeze
      VALID_WORKER_MODES = %i[polling streaming hybrid].freeze
      VALID_POLLING_KWARGS = %i[max_jobs request_timeout].freeze
      VALID_STREAMING_KWARGS = %i[buffer buffer_throttle].freeze

      # Represents a declared input (from variable, header, or both).
      Input = Struct.new(:name, :source, :required, :type, :description, :default,
                         :accessor_name, :define_accessor, keyword_init: true)

      # Represents a declared output returned from perform.
      Output = Struct.new(:name, :required, :type, :description, keyword_init: true)

      attr_accessor :description
      attr_reader :inputs, :outputs, :worker_mode, :polling_config, :streaming_config,
                  :job_timeout, :backoff, :backpressure_delay,
                  :complete_job_on_success, :fail_job_on_error, :strict_outputs, :shutdown_on

      def initialize(worker_class)
        @worker_class = worker_class
        @job_type = nil
        @description = nil
        @inputs = []
        @outputs = []
        @worker_mode = nil
        @polling_config = {}
        @streaming_config = {}
        @job_timeout = nil
        @backoff = nil
        @backpressure_delay = nil
        @complete_job_on_success = true
        @fail_job_on_error = true
        @strict_outputs = nil
        @shutdown_on = []
      end

      def job_type
        @job_type || derive_default_job_type
      end

      def job_type=(value)
        @job_type = value.to_s
      end

      def worker_mode=(value)
        sym = value.to_sym
        unless VALID_WORKER_MODES.include?(sym)
          raise InvalidWorkerDefinition,
                "Invalid worker mode #{value.inspect}. Valid: #{VALID_WORKER_MODES.map(&:inspect).join(', ')}"
        end

        @worker_mode = sym
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

        validate_buffer_option!(kwargs) if kwargs.key?(:buffer)
        validate_no_throttle_without_buffer!(kwargs)
        validate_buffer_throttle!(kwargs) if kwargs.key?(:buffer_throttle)

        @streaming_config = kwargs
      end

      def job_timeout=(value)
        @job_timeout = validate_duration!(:job_timeout, value)
      end

      def backoff=(value)
        @backoff = validate_duration!(:backoff, value)
      end

      def backpressure_delay=(value)
        @backpressure_delay = validate_duration!(:backpressure_delay, value)
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

      def strict_outputs=(value)
        unless [true, false].include?(value)
          raise InvalidWorkerDefinition, "`strict_outputs` requires a boolean, got #{value.inspect}"
        end

        @strict_outputs = value
      end

      # Resolved strict_outputs: per-worker setting falls back to gem-level default.
      def strict_outputs?
        @strict_outputs.nil? ? Busybee.default_strict_outputs : @strict_outputs
      end

      def add_shutdown_on(*exception_classes)
        exception_classes.each do |klass|
          unless klass.is_a?(Class) && klass <= StandardError
            raise InvalidWorkerDefinition,
                  "`shutdown_on` expects StandardError subclasses, got #{klass.inspect}"
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

      # Resolved buffer throttle for the streaming pump thread.
      # Returns false (no throttling), 0 (minimal throttle), or a positive Numeric (ms).
      def buffer_throttle
        streaming_config.fetch(:buffer_throttle, Busybee.default_buffer_throttle)
      end

      # Whether this worker uses a pump thread + buffer for streaming.
      # Default: true. Set to false via `streaming buffer: false` for inline stream processing.
      def buffer?
        streaming_config.fetch(:buffer, Busybee::Defaults::DEFAULT_STREAMING_BUFFER)
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
          worker_mode: worker_mode,
          polling_config: polling_config,
          streaming_config: streaming_config,
          job_timeout: job_timeout,
          backoff: backoff,
          backpressure_delay: backpressure_delay,
          complete_job_on_success: complete_job_on_success,
          fail_job_on_error: fail_job_on_error,
          strict_outputs: strict_outputs?,
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

      def validate_buffer_option!(kwargs)
        return if [true, false].include?(kwargs[:buffer])

        raise InvalidWorkerDefinition, "`buffer:` requires a boolean, got #{kwargs[:buffer].inspect}"
      end

      def validate_no_throttle_without_buffer!(kwargs)
        return unless kwargs[:buffer] == false && kwargs.key?(:buffer_throttle)

        raise InvalidWorkerDefinition,
              "`buffer_throttle:` cannot be set when `buffer: false` — there is no buffer to throttle"
      end

      def validate_buffer_throttle!(kwargs)
        # Coerce: true → 0 ("enable at minimal setting"), nil → false ("no throttling")
        kwargs[:buffer_throttle] = 0 if kwargs[:buffer_throttle] == true
        kwargs[:buffer_throttle] = false if kwargs[:buffer_throttle].nil?

        value = kwargs[:buffer_throttle]
        return if value == false
        return if value.is_a?(Numeric) && value >= 0

        raise InvalidWorkerDefinition,
              "`buffer_throttle:` must be a non-negative Numeric, got #{value.inspect}"
      end

      # The gem-wide duration contract (Durations), re-raised in the DSL's own
      # error vocabulary. Returns the value to assign (numeric Strings coerce).
      def validate_duration!(attr, value)
        Busybee::Durations.validate!(attr, value)
      rescue ArgumentError => e
        raise InvalidWorkerDefinition, e.message
      end
    end
  end
end
