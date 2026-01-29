# frozen_string_literal: true

require "busybee/job"
require "busybee/grpc/error"

module Busybee
  # Wraps a gRPC server stream of activated jobs with a Ruby-idiomatic interface.
  #
  # JobStream is Enumerable, providing `each`, `map`, `select`, and other
  # collection methods. Each yielded element is a {Busybee::Job} instance.
  #
  # @note Streams are single-pass. Once consumed via `each`, `map`, etc., the
  #   stream is exhausted. Subsequent iteration yields nothing. This is inherent
  #   to streaming. To process jobs multiple times, collect them into an array first.
  #
  # @example Process jobs from a stream
  #   stream = client.open_job_stream("send-email", job_timeout: 60.seconds)
  #   trap("INT") { stream.close }
  #
  #   stream.each do |job|
  #     send_email(job.variables.to, job.variables.subject)
  #     job.complete!
  #   end
  #
  # @example Using Enumerable methods
  #   stream = client.open_job_stream("process-order")
  #   high_priority = stream.select { |job| job.variables.priority == "high" }
  #
  class JobStream
    include Enumerable

    # Create a new JobStream wrapper.
    #
    # @param operation [GRPC::ActiveCall::Operation] The gRPC operation (from return_op: true)
    # @param client [Busybee::Client] The client for job operations
    def initialize(operation, client:)
      @operation = operation
      @enumerator = operation.execute
      @client = client
      @closed = false
    end

    # Iterate over jobs in the stream.
    #
    # @yield [job] Yields each job to the block
    # @yieldparam job [Busybee::Job] The activated job
    # @return [Enumerator] If no block given
    # @return [self] If block given
    # @raise [Busybee::StreamAlreadyClosed] If the stream has been closed
    # @raise [Busybee::GRPC::Error] If the stream encounters a gRPC error
    def each
      raise Busybee::StreamAlreadyClosed, "Cannot iterate a closed stream" if closed?
      return enum_for(:each) unless block_given?

      @enumerator.each do |raw_job|
        yield Busybee::Job.new(raw_job, client: @client)
      end
    rescue ::GRPC::Cancelled
      # Expected when stream is closed via #close - exit gracefully
      nil
    rescue ::GRPC::BadStatus
      raise Busybee::GRPC::Error, "Job stream failed"
    end

    # Close the stream.
    #
    # Cancels the underlying gRPC operation. This method is idempotent;
    # calling it multiple times has no additional effect.
    #
    # @return [void]
    def close
      return if @closed

      @operation.cancel
      @closed = true
    end

    # Check if the stream has been closed.
    #
    # @return [Boolean] true if the stream has been closed
    def closed?
      @closed
    end
  end
end
