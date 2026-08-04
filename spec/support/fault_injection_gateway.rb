# frozen_string_literal: true

require "grpc"

require "busybee"
require "busybee/credentials/insecure" # lazily required by Credentials.build, so name it here

# An in-process Zeebe gateway that returns whatever a spec programs it to return,
# so error paths run through busybee's real public API with nothing of busybee's
# own doubled. Deliberately plain Ruby — no RSpec, no spec_helper, no shared
# contexts — so the RSpec integration stays a thin, separable wrapper.
class FaultInjectionGateway
  # Loopback only. Never 0.0.0.0: that prompts the macOS firewall and exposes the
  # port off-host. Overridable because it is the one seam an exotic environment
  # (a UDS path, a different interface) needs to redirect.
  DEFAULT_BIND = "127.0.0.1:0"

  # One handler per Gateway RPC, defined off the generated rpc_descs so the set
  # can never drift from the service definition. Every RPC routes through the
  # gateway's dispatcher, which is what makes request recording uniform.
  class Service < Busybee::GRPC::Gateway::Service
    def initialize(gateway)
      super()
      @gateway = gateway
    end

    Busybee::GRPC::Gateway::Service.rpc_descs.each_key do |name|
      # Underscored, matching busybee's own rpc vocabulary (Call#rpc, run_hooked).
      rpc = ::GRPC::GenericService.underscore(name.to_s).to_sym
      define_method(rpc) { |request, _call| @gateway.dispatch(rpc, request) }
    end
  end

  BindError = Class.new(StandardError)

  # A real ActivatedJob proto, because the harness has to serialize it over an
  # actual wire — the suite's other job factory builds an RSpec double, which
  # cannot. Defaults keep a spec to the fields it actually cares about.
  def self.activated_job(type: "test", variables: {}, headers: {}, key: nil, # rubocop:disable Metrics/ParameterLists
                         bpmn_process_id: "test-process", element_id: "test-element",
                         retries: 3, worker: "test-worker", tenant_id: nil)
    Busybee::GRPC::ActivatedJob.new(
      key: key || rand(100_000..999_999),
      type: type,
      processInstanceKey: rand(100_000..999_999),
      bpmnProcessId: bpmn_process_id,
      elementId: element_id,
      retries: retries,
      worker: worker,
      deadline: (Time.now.to_i + 300) * 1000,
      variables: Busybee::Serialization.to_json(variables),
      customHeaders: Busybee::Serialization.to_json(headers),
      tenantId: tenant_id.to_s
    )
  end

  # The address actually bound — port 0 asks the kernel for a free one, so this
  # is only known after #start. nil means "not currently running".
  attr_reader :address

  def initialize(bind: DEFAULT_BIND)
    @bind = bind
    @handlers = {}
    @received = Hash.new { |h, k| h[k] = [] }
    @mutex = Mutex.new
  end

  # Program an RPC. The block *is* the gRPC handler, so it keeps grpc-ruby's own
  # contract: return a response (streaming: an Enumerable of them) for OK, raise
  # a GRPC::BadStatus for that status, raise anything else for UNKNOWN.
  def on(rpc, &block)
    @handlers[rpc] = block
    self
  end

  # Requests this RPC actually received, in order. Recorded for every RPC whether
  # or not one was programmed, so "did the mutated request reach the wire?" is
  # answerable without programming a behavior first.
  def received(rpc) = @mutex.synchronize { @received[rpc].dup }

  # A client built through the entirely real path — real Insecure credentials,
  # real Credentials#grpc_stub, real channel args. Only the address differs from
  # production, which is the one thing that has to.
  def client
    @client ||= Busybee::Client.new(Busybee::Credentials::Insecure.new(cluster_address: address))
  end

  # Called on a gRPC pool thread, not the spec's thread — hence the mutex.
  def dispatch(rpc, request)
    @mutex.synchronize { @received[rpc] << request }
    handler = @handlers[rpc]
    raise ::GRPC::Unimplemented, "no behavior programmed for #{rpc}" unless handler

    handler.call(request)
  end

  def start
    @server = ::GRPC::RpcServer.new(pool_size: 2)
    port = bind_port!
    @address = @bind.sub(/:\d+\z/, ":#{port}")
    @server.handle(Service.new(self))
    @thread = Thread.new { @server.run }
    @server.wait_till_running
    self
  end

  # Safe to call when start never got as far as binding, which is exactly what an
  # `ensure` block does after a failed boot.
  def stop
    return self unless @address

    @server.stop
    @thread&.join(5)
    @address = nil
    self
  end

  private

  # grpc reports a bind failure inconsistently — 1.81 raises "not sure why",
  # other versions return port 0 — and neither names the knob that fixes it.
  # Collapse both into one error that says what to do about it.
  def bind_port!
    port = begin
      @server.add_http2_port(@bind, :this_port_is_insecure)
    rescue ::RuntimeError
      raise BindError, bind_failure_message # cause is auto-set from the in-flight error
    end
    raise BindError, bind_failure_message if port.zero?

    port
  end

  def bind_failure_message
    "could not bind the fault-injection gateway to #{@bind} — pass " \
      "bind: to FaultInjectionGateway.new if this environment cannot bind loopback"
  end
end
