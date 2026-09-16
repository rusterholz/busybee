# frozen_string_literal: true

# Builders for the busybee carriers a demo spec needs as fixtures.
#
# The rule they encode: never double a carrier. A hook reads projections off a
# Job, a Worker::Status or a Call, so a hand-authored double freezes this suite's
# belief about them into its assertions — rename a key and the app breaks while
# every example stays green. These build what production builds, by its routes.
# Prototypes of the gem's build_test_*; named build_demo_* so they can't shadow it.
module DemoCarriers
  # Snapshot every hook registry, run, restore. The registry is the only seam, and
  # this is the primitive behind both "silence the app's hooks" and "add observers
  # without leaking them into the next example".
  def with_hook_registry
    saved = Busybee::Hooks::HOOK_TYPES.to_h { |type| [type, Busybee::Hooks.hooks_for(type).dup] }
    yield
  ensure
    saved.each { |type, hooks| Busybee::Hooks.hooks_for(type).replace(hooks) }
  end

  # Fixture construction must not fire hooks. Resolving a job runs a real client
  # call, and the demo's after_call hooks would record the fixture as if it were
  # the run under test.
  def without_app_hooks
    with_hook_registry do
      Busybee::Hooks.reset!
      yield
    end
  end

  # The proto the gateway actually sends. Real, not a double — it validates its
  # own field types, and only a real message can cross a wire.
  def build_demo_raw_job(type: "test", key: nil, variables: {}, headers: {}, # rubocop:disable Metrics/ParameterLists
                         bpmn_process_id: "test-process", element_id: "service-task",
                         retries: 3, worker: nil, tenant_id: nil)
    Busybee::GRPC::ActivatedJob.new(
      key: key || rand(100_000..999_999),
      type: type.to_s,
      processInstanceKey: rand(100_000..999_999),
      bpmnProcessId: bpmn_process_id,
      elementId: element_id,
      retries: retries,
      worker: (worker || Busybee.worker_name).to_s,
      deadline: (Time.now.to_i + 300) * 1000,
      variables: Busybee::Serialization.to_json(variables),
      customHeaders: Busybee::Serialization.to_json(headers),
      tenantId: tenant_id.to_s
    )
  end

  # A Job wrapped and contextualised the way Runner#activate_job does it, so the
  # activation facts a hook reads (source, buffered?, worker_class, worker_status)
  # arrive by their real route rather than being stubbed onto the instance.
  def build_demo_job(client: nil, worker_class: nil, worker_status: nil, # rubocop:disable Metrics/ParameterLists
                     source: :poll, buffered: false, activated: true, **proto)
    job = Busybee::Job.new(build_demo_raw_job(**proto), client: client)
    job.set_context(worker_class: worker_class, worker_status: worker_status,
                    source: source, buffered: buffered)
    job.timestamps.stamp!(:activated_at) if activated
    job
  end

  # A real Worker::Status. Note what it refuses that a double allowed: job_type is
  # derived from worker_class rather than set beside it, so the two cannot
  # disagree; error_message comes from a real exception; and worker_name is not a
  # field at all — it reads through to Busybee.worker_name at call time.
  def build_demo_worker_status(worker_class: Oms::UpdateOrderStatusWorker, worker_mode: :hybrid,
                               moments: [:started_at], **attrs)
    timestamps = Busybee::Worker::Timestamps.new
    moments.each { |moment| timestamps.stamp!(moment) }
    Busybee::Worker::Status.new(worker_class: worker_class, worker_mode: worker_mode,
                                timestamps: timestamps, **attrs)
  end

  # Drive a real Call through its real state machine — the underscore seam the
  # client itself drives — so logging_context and context_tags compute instead of
  # being written down here. `attempted: false` leaves it with no observed network
  # time; a job in scope correlates it, and note that a job's own worker_status
  # wins over any separately seeded one (Call::Correlation).
  def build_demo_call(rpc, request = nil, gateway:, job: nil, worker_status: nil, # rubocop:disable Metrics/ParameterLists
                      status: :succeeded, attempted: true, network: 0.002, error: nil)
    correlating(job, worker_status) do
      call = Busybee::Client::Call.new(rpc, request)
      if attempted
        attempt_demo_call(call, rpc, request, gateway, status, network, error)
        call._resolve(status: status)
      end
      call
    end
  end

  private

  def attempt_demo_call(call, rpc, request, gateway, status, network, error) # rubocop:disable Metrics/ParameterLists
    call.attempt do
      sleep network
      raise(error || ::GRPC::Unavailable, "broker unreachable") if status == :errored

      gateway.dispatch(rpc, request)
    end
  rescue Busybee::GRPC::Error
    nil # the seam re-raises past the chain; with_hooks resolves either way
  end

  def correlating(job, worker_status, &)
    return Busybee::Client::Call.with_job(job, &) if job
    return Busybee::Client::Call.with_worker_status(worker_status, &) if worker_status

    yield
  end
end
