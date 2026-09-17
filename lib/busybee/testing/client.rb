# frozen_string_literal: true

require "grpc"

require "busybee/client"
require "busybee/credentials/insecure"
require "busybee/grpc"

module Busybee
  module Testing
    # A real Busybee::Client whose transport is in-process: run_hooked, the Call
    # carrier, retry, request mutation and the three call hooks are all genuine,
    # and only the gRPC stub is substituted. A *doubled* client sits above
    # run_hooked — the seam call hooks hang off — so with one in place no call
    # hook can fire at all.
    #
    # Programming it keeps grpc-ruby's contract: the block **is** the handler, so
    # return a response message for OK and raise a GRPC::BadStatus subclass for
    # that status.
    #
    # @example Program a failure and watch your worker cope
    #   client = build_test_client
    #   client.on(:complete_job) { raise GRPC::Internal, "storage unavailable" }
    #
    # @example Assert what reached the wire
    #   expect(client.received(:publish_message).map(&:name)).to eq(["order-ready"])
    class Client < Busybee::Client
      # Enough of a response for an operation that only needs one to exist. Listed
      # rather than derived from the service descriptor: the gateway declares more
      # RPCs than busybee issues, and one of these is a stream, not a message.
      DEFAULT_RESPONSES = {
        activate_jobs: -> { [] }, # server-streaming: a stream of responses, empty meaning "no work"
        broadcast_signal: -> { Busybee::GRPC::BroadcastSignalResponse.new },
        complete_job: -> { Busybee::GRPC::CompleteJobResponse.new },
        fail_job: -> { Busybee::GRPC::FailJobResponse.new },
        publish_message: -> { Busybee::GRPC::PublishMessageResponse.new },
        set_variables: -> { Busybee::GRPC::SetVariablesResponse.new },
        throw_error: -> { Busybee::GRPC::ThrowErrorResponse.new },
        update_job_retries: -> { Busybee::GRPC::UpdateJobRetriesResponse.new },
        update_job_timeout: -> { Busybee::GRPC::UpdateJobTimeoutResponse.new }
      }.freeze

      # Stands where Busybee::GRPC::Gateway::Stub stands, sharing the client's own
      # handler and record hashes so later programming still takes effect.
      class Stub
        def initialize(handlers, received)
          @handlers = handlers
          @received = received
        end

        def method_missing(rpc, request, **)
          return super unless known?(rpc)

          @received[rpc] << request
          handler = @handlers[rpc]
          handler ? handler.call(request) : DEFAULT_RESPONSES.fetch(rpc).call
        end

        def respond_to_missing?(rpc, include_private = false)
          known?(rpc) || super
        end

        private

        def known?(rpc) = @handlers.key?(rpc) || DEFAULT_RESPONSES.key?(rpc)
      end

      def initialize(cluster_address: "in-process")
        super(Busybee::Credentials::Insecure.new(cluster_address: cluster_address))
        @handlers = {}
        @received = Hash.new { |hash, rpc| hash[rpc] = [] }
      end

      # Program an RPC, replacing any default. Chainable.
      #
      # @param rpc [Symbol] the underscored RPC name, as Call#rpc reports it
      # @yieldparam request [Object] the request proto that reached the wire
      def on(rpc, &block)
        @handlers[rpc] = block
        self
      end

      # Requests this RPC received, oldest first, programmed or not.
      #
      # @param rpc [Symbol] the underscored RPC name
      # @return [Array] the request protos
      def received(rpc) = @received[rpc].dup

      private

      def stub = @stub ||= Stub.new(@handlers, @received)
    end
  end
end
