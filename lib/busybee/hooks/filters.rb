# frozen_string_literal: true

require "grpc"

module Busybee
  module Hooks
    # What the prefilter kwargs accept, and what each carrier can actually hold
    # at the moment a given hook fires. Registration checks a filter against
    # both, so one that could never match is refused at boot instead of quietly
    # never firing.
    module Filters
      # gRPC's own status set, so an upgrade there cannot leave this behind.
      GRPC_STATUSES = ::GRPC::Core::StatusCodes.constants.map { |name| name.to_s.downcase.to_sym }.freeze

      # The RPCs busybee itself issues — deliberately not the gateway's full
      # descriptor list, which carries seven calls busybee never makes and would
      # therefore accept filters that can never fire.
      RPCS = %i[
        activate_jobs broadcast_signal cancel_process_instance complete_job
        create_process_instance deploy_resource fail_job publish_message
        resolve_incident set_variables stream_activated_jobs throw_error
        update_job_retries update_job_timeout
      ].freeze

      JOB_STATUSES = %i[ready complete failed error].freeze
      JOB_SOURCES = %i[poll stream].freeze
      WORKER_MODES = %i[polling streaming hybrid].freeze
      CALL_STATUSES = %i[pending succeeded errored].freeze

      # Filter keys per noun, as [domain, vocabulary]. A nil vocabulary is an
      # open one — job types, process ids, worker classes and stop reasons are
      # all minted by the adopter, so only the domain can be checked.
      FILTERS = {
        job: {
          job_type: [:name], worker_class: [:class], status: [:name, JOB_STATUSES],
          bpmn_process_id: [:name], source: [:name, JOB_SOURCES],
          buffered: [:boolean], error: [:error]
        }.freeze,
        worker: {
          worker_class: [:class], job_type: [:name], worker_mode: [:name, WORKER_MODES],
          reason: [:name], error: [:error]
        }.freeze,
        call: {
          rpc: [:name, RPCS], status: [:name, CALL_STATUSES],
          grpc_status: [:name, GRPC_STATUSES], error: [:error]
        }.freeze
      }.freeze

      # Where a hook's moment narrows its noun's vocabulary. Around-hooks are
      # here because filters are read when hooks are SELECTED — before the work
      # runs — so they see the entry state, never the outcome. `[nil]` means the
      # reader is always nil there, which only `error: false` can match.
      MOMENTS = {
        before_perform: { status: %i[ready], error: [nil] },
        around_perform: { status: %i[ready], error: [nil] },
        on_job_activated: { status: %i[ready], error: [nil] },
        around_job_execution: { status: %i[ready], error: [nil] },
        before_call: { status: %i[pending], grpc_status: [nil], error: [nil] },
        around_call: { status: %i[pending], grpc_status: [nil], error: [nil] },
        after_call: { status: %i[succeeded errored] },
        on_worker_started: { reason: [nil], error: [nil] },
        on_worker_stop_requested: { error: [nil] }
      }.freeze

      # Matchers each domain accepts. Regexp and Proc ride along everywhere they
      # could mean anything; String and Symbol are interchangeable throughout.
      SHAPES = {
        name: [String, Symbol, Regexp, Proc].freeze,
        class: [Module, String, Symbol, Regexp, Proc].freeze,
        boolean: [TrueClass, FalseClass, Proc].freeze
      }.freeze

      class << self
        # ====== Matching ======

        # Test whether a filter matches a value. Arrays match any element; scalars
        # match by case equality, then equality (Class identity), then by name —
        # and a Class is additionally offered its own name, so the same matchers
        # reach it however the adopter spelled the class.
        def match?(filter, value)
          return filter.any? { |element| match?(element, value) } if filter.is_a?(Array)

          scalar_match?(filter, value) || (value.is_a?(Class) && scalar_match?(filter, value.name))
        end

        # The error: filter's semantics — the filter describes the error, or its
        # absence. With no error present only `false` matches, every other matcher
        # requires one (Procs aren't even called on nil); an Array matches if any
        # element does.
        def error_match?(filter, error)
          return error.nil? if filter == false
          return false if error.nil?
          return filter.any? { |element| error_match?(element, error) } if filter.is_a?(Array)

          present_error_match?(filter, error)
        end

        # Whether all of a hook's filters match the target. Keys are read off the
        # carrier by public_send. Empty filters match everything (vacuous truth).
        def matches?(hook, target)
          hook[:filters].all? { |key, filter| filter_match?(key, filter, attribute(target, key)) }
        end

        # Per-key matcher dispatch: :error gets its semantic table; every other
        # key goes through the generic match.
        def filter_match?(key, filter, value)
          key == :error ? error_match?(filter, value) : match?(filter, value)
        end

        # Look up a filter key against the target. A missing key reads as nil, so
        # a filter can express "only when this attribute is set".
        def attribute(target, key)
          target.respond_to?(key) ? target.public_send(key) : nil
        end

        # ====== Registration-time validation ======

        # Refuse a filter that cannot match anything the carrier will hold when
        # this hook fires. Procs are exempt from the reachability half: they
        # cannot be read statically, and calling an adopter's Proc against
        # invented values is not validation's business.
        def validate!(type, noun, filters)
          return if filters.empty?

          allowed = FILTERS.fetch(noun)
          unknown = filters.keys - allowed.keys
          unless unknown.empty?
            raise ArgumentError, "Unknown filter(s) for #{type}: #{unknown.join(', ')}. " \
                                 "Allowed: #{allowed.keys.join(', ')}"
          end

          filters.each { |key, filter| validate_value!(type, key, filter, allowed.fetch(key)) }
        end

        private

        def scalar_match?(filter, value)
          filter === value || filter == value || name_match?(filter, value)
        end

        # Names are spellings, not types: a filter and a value that are both
        # String-or-Symbol match when they spell the same thing.
        def name_match?(filter, value)
          name?(filter) && name?(value) && filter.to_s == value.to_s
        end

        def name?(object) = object.is_a?(String) || object.is_a?(Symbol)

        # Name-domain matchers (String/Regexp) see only the error's own class
        # name, never its ancestry — hierarchy matching takes the live
        # Class/Module, mirroring rescue.
        def present_error_match?(filter, error)
          case filter
          when true then true
          when Module then error.is_a?(filter)
          when String then error.class.name == filter # rubocop:disable Style/ClassEqualityComparison
          when Regexp then filter.match?(error.class.name)
          when Proc then !!filter.call(error)
          else false
          end
        end

        def validate_value!(type, key, filter, spec)
          domain, vocabulary = spec
          domain == :error ? validate_error_filter!(filter) : validate_shape!(type, key, filter, domain)
          validate_reachable!(type, key, filter, MOMENTS.dig(type, key) || vocabulary)
        end

        def validate_shape!(type, key, filter, domain)
          return filter.each { |element| validate_shape!(type, key, element, domain) } if filter.is_a?(Array)
          return if SHAPES.fetch(domain).any? { |shape| filter.is_a?(shape) }

          raise ArgumentError,
                "#{type} filter #{key}: #{filter.inspect} cannot express a match. " \
                "#{key}: accepts #{readable(SHAPES.fetch(domain))}, or an Array of these."
        end

        def validate_reachable!(type, key, filter, values)
          return if values.nil?
          return filter.each { |element| validate_reachable!(type, key, element, values) } if filter.is_a?(Array)
          return if reachable?(key, filter, values)

          raise ArgumentError,
                "#{type} filter #{key}: #{filter.inspect} can never match. " \
                "#{key} is #{readable(values.map(&:inspect))} when #{type} fires."
        end

        def reachable?(key, filter, values)
          filter.is_a?(Proc) || values.any? { |value| filter_match?(key, filter, value) }
        end

        # Reject error: values outside the semantic table loudly at registration —
        # under generic matching an implausible matcher (a Regexp against an
        # exception instance) compiled fine and silently never fired.
        def validate_error_filter!(filter)
          case filter
          when true, false, Module, String, Regexp, Proc then nil
          when Array then filter.each { |element| validate_error_filter!(element) }
          when nil
            raise ArgumentError,
                  "error: does not accept nil inside an array — use `error: false` to match \"no error\""
          else
            raise ArgumentError,
                  "error: accepts true/false, an exception Class or Module, a String or Regexp " \
                  "(matched against the error's class name), a Proc, or an Array of these; " \
                  "got #{filter.inspect}"
          end
        end

        def readable(items)
          names = items.map(&:to_s)
          return names.first if names.one?

          "#{names[0..-2].join(', ')} or #{names.last}"
        end
      end
    end
  end
end
