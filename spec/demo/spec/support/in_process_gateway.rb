# frozen_string_literal: true

require "busybee"
require "busybee/credentials/insecure"

# An in-process stand-in for the Zeebe gateway, so demo specs exercise the real
# client seam without a broker: Client, run_hooked, the Call carrier, retry and
# the call hooks are all genuine, and only the gRPC stub is ours. A spec that
# doubles the client instead doubles the very seam call hooks hang off, and then
# no call hook can fire at all.
#
# Handler contract is the gem's own (spec/support/fault_injection_gateway.rb):
# the block IS the handler — return a response for OK, raise a GRPC::BadStatus
# subclass for that status. One vocabulary, whichever side you test from.
class InProcessGateway
  # Responses that keep a demo spec to the fields it cares about. The gem's
  # operations only read a response when they return something to the caller.
  DEFAULT_RESPONSES = {
    # Server-streaming: the caller iterates responses, so this is a stream of
    # them. Empty is the honest idle default — a long poll that found no work.
    activate_jobs: -> { [] },
    complete_job: -> { Busybee::GRPC::CompleteJobResponse.new },
    fail_job: -> { Busybee::GRPC::FailJobResponse.new },
    throw_error: -> { Busybee::GRPC::ThrowErrorResponse.new },
    update_job_retries: -> { Busybee::GRPC::UpdateJobRetriesResponse.new },
    update_job_timeout: -> { Busybee::GRPC::UpdateJobTimeoutResponse.new },
    publish_message: -> { Busybee::GRPC::PublishMessageResponse.new }
  }.freeze

  # The stub the Client talks to. Not a double: a real object standing exactly
  # where Busybee::GRPC::Gateway::Stub stands, dispatching by RPC name.
  class Stub
    def initialize(gateway)
      @gateway = gateway
    end

    def method_missing(rpc, request, **)
      return super unless @gateway.knows?(rpc)

      @gateway.dispatch(rpc, request, **)
    end

    def respond_to_missing?(rpc, include_private = false)
      @gateway.knows?(rpc) || super
    end
  end

  def initialize
    @handlers = {}
    @received = Hash.new { |hash, rpc| hash[rpc] = [] }
  end

  # Program an RPC, replacing any default. Returns self so it chains.
  def on(rpc, &block)
    @handlers[rpc] = block
    self
  end

  # Requests this RPC actually received, in order — recorded whether or not a
  # behavior was programmed, so "did it reach the wire?" needs no setup.
  def received(rpc) = @received[rpc].dup

  def knows?(rpc) = @handlers.key?(rpc) || DEFAULT_RESPONSES.key?(rpc)

  def dispatch(rpc, request, **)
    @received[rpc] << request
    handler = @handlers[rpc]
    return handler.call(request) if handler

    DEFAULT_RESPONSES.fetch(rpc).call
  end

  # A real Client over this gateway. The credentials object is genuine too —
  # only its stub is redirected, which is the one thing that has to differ.
  def client
    @client ||= Busybee::Client.new(credentials)
  end

  private

  def credentials
    stub = Stub.new(self)
    Busybee::Credentials::Insecure.new(cluster_address: "in-process").tap do |creds|
      creds.define_singleton_method(:grpc_stub) { stub }
    end
  end
end
