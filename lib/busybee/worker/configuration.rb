# frozen_string_literal: true

require "active_support/core_ext/string/inflections"

module Busybee
  class Worker
    # Stores all DSL-declared metadata for a Worker subclass.
    # Lazily instantiated per worker class via Worker.configuration.
    class Configuration
      # Represents a declared input (from variable, header, or both).
      # Mission 8: DSL methods (input, variable, header) will create these.
      Input = Struct.new(:name, :source, :required, :type, :description, :default,
                         :accessor_name, :define_accessor, keyword_init: true)

      # Represents a declared output returned from perform.
      # Mission 8: output DSL method will create these.
      Output = Struct.new(:name, :required, :type, :description, keyword_init: true)

      attr_accessor :description
      attr_reader :inputs, :outputs

      def initialize(worker_class)
        @worker_class = worker_class
        @job_type = nil
        @description = nil
        @inputs = []
        @outputs = []
        # Mission 8: runner_mode, polling config, streaming config, job_timeout, backoff
        # Mission 9: autocomplete, autofail, unhealthy_on
      end

      def job_type
        @job_type || derive_default_job_type
      end

      def job_type=(value)
        @job_type = value.to_s
      end

      def to_h
        {
          job_type: job_type,
          description: description,
          inputs: inputs.map(&:to_h),
          outputs: outputs.map(&:to_h)
          # Mission 8: runner_mode, polling, streaming, job_timeout, backoff
          # Mission 9: autocomplete, autofail, unhealthy_on
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
    end
  end
end
