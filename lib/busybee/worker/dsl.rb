# frozen_string_literal: true

require "busybee/error"
require "busybee/worker/configuration"

module Busybee
  class Worker
    # Class-level DSL for declaring worker metadata and configuration.
    # Extended into Worker subclasses.
    module DSL
      # Sentinel for distinguishing "not passed" from "passed as nil".
      NOT_SET = Object.new.freeze
      private_constant :NOT_SET

      # Ruby keywords that can't be used as bare method calls (obj.keyword is a syntax error).
      RUBY_KEYWORDS = %w[
        __FILE__ __LINE__ __ENCODING__
        BEGIN END
        alias and begin break case class def defined? do
        else elsif end ensure false for if in module next
        nil not or redo rescue retry return self super
        then true undef unless until when while yield
      ].freeze
      private_constant :RUBY_KEYWORDS

      def configuration
        @configuration ||= Configuration.new(self)
      end

      def job_type(value = nil)
        if value.nil?
          configuration.job_type
        else
          configuration.job_type = value
        end
      end

      def description(value = nil)
        if value.nil?
          configuration.description
        else
          configuration.description = value
        end
      end

      def input(name, source:, required: NOT_SET, type: nil, description: nil, # rubocop:disable Metrics/ParameterLists
                default: NOT_SET, accessor_name: nil, define_accessor: true)
        validate_required_default_exclusivity!(name, required, default)

        input_struct = Configuration::Input.new(
          name: name.to_sym,
          source: normalize_source(source),
          required: resolve_required(required, default),
          type: type,
          description: description,
          default: default == NOT_SET ? nil : default,
          accessor_name: accessor_name&.to_sym,
          define_accessor: define_accessor
        )
        configuration.add_input(input_struct)
        define_input_accessor(input_struct) if define_accessor
      end

      def variable(name, **)
        input(name, source: :variable, **)
      end

      def header(name, **)
        input(name, source: :header, **)
      end

      def output(name, required: NOT_SET, type: nil, description: nil)
        output_struct = Configuration::Output.new(
          name: name.to_sym,
          required: required == NOT_SET ? Busybee.default_output_required : !!required,
          type: type,
          description: description
        )
        configuration.add_output(output_struct)
      end

      def worker_mode(value)
        configuration.worker_mode = value
      end

      def polling(**kwargs)
        configuration.polling_config = kwargs
      end

      def streaming(**kwargs)
        configuration.streaming_config = kwargs
      end

      def job_timeout(value)
        configuration.job_timeout = value
      end

      def fail_job_backoff(value)
        configuration.fail_job_backoff = value
      end

      def backpressure_delay(value = nil)
        if value.nil?
          configuration.backpressure_delay
        else
          configuration.backpressure_delay = value
        end
      end

      def complete_job_on_success(value = nil)
        if value.nil?
          configuration.complete_job_on_success
        else
          configuration.complete_job_on_success = value
        end
      end

      def strict_outputs(value = nil)
        if value.nil?
          configuration.strict_outputs?
        else
          configuration.strict_outputs = value
        end
      end

      def shutdown_on(*exception_classes)
        if exception_classes.empty?
          configuration.shutdown_on
        else
          configuration.add_shutdown_on(*exception_classes)
        end
      end

      private

      def normalize_source(source)
        Array(source).map(&:to_sym)
      end

      def resolve_required(required, default)
        # If default is provided and required wasn't explicitly set, input is not required
        return false if required == NOT_SET && default != NOT_SET

        required == NOT_SET ? Busybee.default_input_required : !!required
      end

      def validate_required_default_exclusivity!(name, required, default)
        return unless required != NOT_SET && default != NOT_SET

        raise InvalidWorkerDefinition,
              "`required:` and `default:` are mutually exclusive on input :#{name} " \
              "— a default makes the input always available, so `required:` is meaningless"
      end

      def define_input_accessor(input)
        method_name = input.accessor_name || input.name
        validate_accessor_name!(method_name)

        sources = Array(input.source)
        default_value = input.default

        define_method(method_name) do
          sources.each do |src|
            v = public_send(:"#{src}s")[input.name.to_s]
            return v unless v.nil?
          end
          default_value&.clone
        end
      end

      def validate_accessor_name!(name)
        str_name = name.to_s

        if RUBY_KEYWORDS.include?(str_name)
          raise InvalidWorkerDefinition,
                "Cannot define accessor :#{name} — it's a Ruby keyword. " \
                "Use `accessor_name:` or `define_accessor: false`"
        end

        return unless method_defined?(name) || private_method_defined?(name)

        raise InvalidWorkerDefinition,
              "A method :#{name} already exists on #{self.name || 'this worker'}. " \
              "Use `accessor_name:` or `define_accessor: false`"
      end
    end
  end
end
