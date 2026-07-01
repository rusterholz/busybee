# frozen_string_literal: true

module Busybee
  module Hooks
    # Shared timing behavior for the per-carrier *::Timestamps value objects
    # (Job::Timestamps, Client::Call::Timestamps, Worker::Timestamps). Each of
    # those is a noun ("the job's timestamps"); Timing is the behavior they
    # share: one monotonic + UTC stamp pair per moment, a (type = :utc)
    # kind-arg reader idiom, and millisecond duration math. Monotonic stamps
    # drive the math; UTC stamps are exposed for logging.
    #
    # The primitives are deliberately decoupled from any declared set of
    # moments: stamp! and elapsed_ms work on any name by interpolating the
    # ivar, and the `timestamp` macro only defines public readers. That lets a
    # carrier keep private moments it never exposes (e.g. Call carrying a prior
    # attempt's network window forward) with no reader and no registration.
    module Timing
      module ClassMethods
        # Declare public moments: define a reader `name(type = :utc)` for each,
        # over its @name_monotonic / @name_utc pair (nil until stamped), and
        # register the name so the carrier's loggable timestamp set is known.
        # This is the single source of truth for "what are the public moments"
        # — what timestamp_hash dumps, and what a host delegates to its carrier.
        def timestamp(*names)
          (@timestamp_names ||= []).concat(names)
          names.each do |name|
            define_method(name) do |type = :utc|
              case type
              when :utc then instance_variable_get(:"@#{name}_utc")
              when :monotonic then instance_variable_get(:"@#{name}_monotonic")
              else
                raise ArgumentError, "Unknown timestamp type: #{type.inspect}. Expected :utc or :monotonic."
              end
            end
          end
        end

        # The declared public moments, in declaration order. Drives
        # timestamp_hash and is the set a host can delegate to its carrier.
        def timestamp_names
          @timestamp_names ||= []
        end
      end

      def self.included(base)
        base.extend(ClassMethods)
      end

      # Record a moment as a monotonic + UTC pair, to now. Returns self for
      # chaining. Any name is accepted — the macro-defined readers, not stamp!,
      # pin the public surface.
      def stamp!(name)
        instance_variable_set(:"@#{name}_monotonic", Process.clock_gettime(Process::CLOCK_MONOTONIC))
        instance_variable_set(:"@#{name}_utc", Time.now.utc)
        self
      end

      # Every declared moment that has been stamped, as { name => stamp } (UTC
      # by default; :monotonic for the raw clock). The shared loggable-timestamp
      # surface — the timing half of a carrier's observability contract, the
      # cornerstone its logging_context dumps. Driven by the declared set, so
      # private carried-forward moments (stamped but never declared) stay out.
      def timestamp_hash(type = :utc)
        self.class.timestamp_names.each_with_object({}) do |name, hash|
          value = public_send(name, type)
          hash[name] = value unless value.nil?
        end
      end

      private

      # Milliseconds between two moments' monotonic stamps, rounded to 0.1ms;
      # nil unless both are stamped. The sole duration primitive — a carrier
      # whose duration isn't a gap between two moments (e.g. a running sum)
      # computes that itself.
      def elapsed_ms(from, to)
        started = instance_variable_get(:"@#{from}_monotonic")
        finished = instance_variable_get(:"@#{to}_monotonic")
        return nil unless started && finished

        ((finished - started) * 1000).round(1)
      end
    end
  end
end
