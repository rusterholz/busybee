# frozen_string_literal: true

require "busybee/testing"

RSpec.describe Busybee::Testing::Helpers::Builders do
  let(:worker_class) do
    Class.new(Busybee::Worker) do
      job_type "test-worker"
      strict_outputs false

      def perform = { status: "done" }
    end
  end

  describe "#build_test_worker_status" do
    it "returns a real Worker::Status" do
      expect(build_test_worker_status(worker_class: worker_class)).to be_a(Busybee::Worker::Status)
    end

    it "derives job_type from the worker class rather than taking it beside it" do
      status = build_test_worker_status(worker_class: worker_class)

      expect(status.job_type).to eq("test-worker")
    end

    it "carries counters and gauges" do
      status = build_test_worker_status(worker_class: worker_class, total_job_count: 7,
                                        failed_job_count: 2, current_buffer_size: 3)

      expect(status).to have_attributes(total_job_count: 7, failed_job_count: 2, current_buffer_size: 3)
    end

    it "stamps the lifecycle moments it is asked for, and no others" do
      status = build_test_worker_status(worker_class: worker_class,
                                        moments: %i[started_at stop_requested_at])

      expect(status).to have_attributes(started_at: be_a(Time), stop_requested_at: be_a(Time),
                                        stopping_at: nil, shutdown_at: nil)
    end

    it "projects a real exception onto the error axis" do
      status = build_test_worker_status(worker_class: worker_class, error: ArgumentError.new("bad input"))

      expect(status).to have_attributes(error_class: ArgumentError, error_message: "bad input")
    end

    it "reads worker_name live from the gem config, since a Status has no such field" do
      status = build_test_worker_status(worker_class: worker_class)

      expect(status.worker_name).to eq(Busybee.worker_name)
    end
  end

  describe "#build_test_client" do
    around { |example| with_isolated_hooks { example.run } }

    it "is a real Busybee::Client" do
      expect(build_test_client).to be_a(Busybee::Client)
    end

    it "answers the common operations without any programming" do
      expect { build_test_client.complete_job(42, vars: { ok: true }) }.not_to raise_error
    end

    it "takes a programmed response, the block being the handler" do
      client = build_test_client
      client.on(:publish_message) { Busybee::GRPC::PublishMessageResponse.new(key: 99) }

      expect(client.publish_message("order-ready", correlation_key: "order-1")).to eq(99)
    end

    it "turns a raised GRPC::BadStatus into the gem's own error, as the wire would" do
      client = build_test_client
      client.on(:complete_job) { raise GRPC::Internal, "storage unavailable" }

      expect { client.complete_job(42) }.to raise_error(Busybee::GRPC::Error) { |error|
        expect(error.grpc_status).to eq(:internal)
      }
    end

    it "records every request that reached it, programmed or not" do
      client = build_test_client
      client.complete_job(7, vars: { a: 1 })

      expect(client.received(:complete_job).map(&:jobKey)).to eq([7])
    end

    it "records nothing for an rpc that was never called" do
      expect(build_test_client.received(:fail_job)).to be_empty
    end

    # The reason this builder exists. A doubled client sits *above* run_hooked,
    # which is the seam the call hooks hang off, so with one in place no call hook
    # can fire at all — the gap this whole surface was built to close.
    it "fires the call hooks, because everything above the wire is real" do
      observed = []
      Busybee::Hooks.before_call { |call| observed << [:before_call, call.rpc] }
      Busybee::Hooks.after_call { |call| observed << [:after_call, call.rpc, call.status] }

      build_test_client.complete_job(42)

      expect(observed).to eq([%i[before_call complete_job], %i[after_call complete_job succeeded]])
    end

    it "shows a failed call to after_call as errored" do
      statuses = []
      Busybee::Hooks.after_call { |call| statuses << call.status }
      client = build_test_client
      client.on(:complete_job) { raise GRPC::Internal, "nope" }

      expect { client.complete_job(42) }.to raise_error(Busybee::GRPC::Error)
      expect(statuses).to eq([:errored])
    end
  end

  describe "#build_test_job" do
    around { |example| with_isolated_hooks { example.run } }

    it "returns a Busybee::Job" do
      job = build_test_job
      expect(job).to be_a(Busybee::Job)
    end

    it "starts with :ready status" do
      job = build_test_job
      expect(job).to be_ready
    end

    it "parses variables into the job" do
      job = build_test_job(variables: { order_id: 42, name: "test" })
      expect(job.variables[:order_id]).to eq(42)
      expect(job.variables[:name]).to eq("test")
    end

    it "parses headers into the job" do
      job = build_test_job(headers: { algorithm: "haversine" })
      expect(job.headers[:algorithm]).to eq("haversine")
    end

    it "defaults to empty variables and headers" do
      job = build_test_job
      expect(job.variables).to be_empty
      expect(job.headers).to be_empty
    end

    it "uses the provided bpmn_process_id" do
      job = build_test_job(bpmn_process_id: "my-process")
      expect(job.bpmn_process_id).to eq("my-process")
    end

    it "uses the provided retries count" do
      job = build_test_job(retries: 5)
      expect(job.retries).to eq(5)
    end

    it "uses the provided key" do
      job = build_test_job(key: 9876)
      expect(job.key).to eq(9876)
    end

    it "defaults to a random key when none is given" do
      keys = Array.new(5) { build_test_job.key }
      expect(keys.uniq.size).to be > 1
    end

    describe "the client it resolves through" do
      it "accepts complete!" do
        job = build_test_job
        expect { job.complete!(result: "ok") }.not_to raise_error
        expect(job).to be_complete
      end

      it "accepts fail!" do
        job = build_test_job
        expect { job.fail!("something went wrong") }.not_to raise_error
        expect(job).to be_failed
      end

      it "accepts throw_bpmn_error!" do
        job = build_test_job
        expect { job.throw_bpmn_error!(:not_found, "gone") }.not_to raise_error
        expect(job).to be_error
      end

      it "accepts update_retries" do
        job = build_test_job
        expect { job.update_retries(5) }.not_to raise_error
      end

      it "accepts update_timeout" do
        job = build_test_job
        expect { job.update_timeout(30_000) }.not_to raise_error
      end
    end

    # The job is a real ActivatedJob proto, so it validates its own field types.
    # A double accepted anything, which meant a spec could hold a job production
    # could never produce.
    it "refuses a key the wire could not carry" do
      expect { build_test_job(key: "abc") }.to raise_error(Google::Protobuf::TypeError)
    end

    it "exposes the activation facts a hook filters on" do
      status = build_test_worker_status(worker_class: worker_class)
      job = build_test_job(type: "test-worker", worker_class: worker_class,
                           worker_status: status, source: :stream, buffered: true)

      expect(job).to have_attributes(job_type: "test-worker", worker_class: worker_class,
                                     worker_status: status, source: :stream, buffered?: true)
    end

    it "has no source unless given one, as no transport delivered it" do
      expect(build_test_job.source).to be_nil
    end

    it "stamps activation, so a job handed to a hook looks activated" do
      expect(build_test_job.activated_at).to be_a(Time)
    end

    it "can be left unactivated for a spec that stamps the lifecycle itself" do
      expect(build_test_job(activated: false).activated_at).to be_nil
    end

    it "addresses the fields the old fabricated job hardcoded" do
      job = build_test_job(element_id: "review-task", tenant_id: "acme")

      expect(job.element_id).to eq("review-task")
      expect(job.logging_context[:element_id]).to eq("review-task")
    end

    it "resolves through a real client when given one, so call hooks fire" do
      observed = []
      Busybee::Hooks.after_call { |call| observed << [call.rpc, call.job&.key] }
      client = build_test_client
      job = build_test_job(key: 4242, client: client)

      job.complete!(ok: true)

      expect(observed).to eq([[:complete_job, 4242]])
      expect(client.received(:complete_job).map(&:jobKey)).to eq([4242])
    end

    it "hands back a job already in a terminal state when asked" do
      expect(build_test_job(status: :complete)).to be_complete
      expect(build_test_job(status: :failed)).to be_failed
      expect(build_test_job(status: :error)).to be_error
    end

    it "reaches that state through the real resolution, not by assignment" do
      client = build_test_client
      job = build_test_job(key: 77, status: :complete, client: client)

      expect(client.received(:complete_job).map(&:jobKey)).to eq([77])
      expect(job.resolved_at).to be_a(Time)
    end

    # Fixture construction must not fire the hooks the spec is about to observe.
    # Resolving a job runs a real client call, so without suppression a spec's own
    # after_call would record its setup as though it were the run under test.
    it "builds its fixture without firing the hooks under test" do
      fired = []
      Busybee::Hooks.on_job_activated { fired << :activated }
      Busybee::Hooks.after_call { fired << :call }

      build_test_job(status: :complete)

      expect(fired).to be_empty
    end

    it "leaves the registry as it found it" do
      Busybee::Hooks.after_call { nil }

      build_test_job(status: :complete)

      expect(Busybee::Hooks.hooks_for(:after_call).size).to eq(1)
    end
  end

  describe "#build_test_call" do
    it "returns a real Call driven through its own state machine" do
      call = build_test_call(:complete_job)

      expect(call).to be_a(Busybee::Client::Call)
      expect(call).to have_attributes(rpc: :complete_job, attempts: 1, status: :succeeded, grpc_status: :ok)
    end

    it "observes a real network span rather than being told one" do
      call = build_test_call(:complete_job)

      expect(call.network_ms).to be > 0
    end

    it "leaves an unattempted call with nothing observed" do
      call = build_test_call(:complete_job, attempted: false)

      expect(call).to have_attributes(attempts: 0, network_ms: nil)
      expect(call).to be_pending
    end

    it "carries the result the wire handed back" do
      response = Busybee::GRPC::CompleteJobResponse.new

      expect(build_test_call(:complete_job, result: response).result).to eq(response)
    end

    it "records a failure the way the seam records one" do
      call = build_test_call(:complete_job, status: :errored, error: GRPC::Internal.new("storage gone"))

      expect(call).to be_errored
      expect(call.error).to be_a(Busybee::GRPC::Error)
      expect(call.grpc_status).to eq(:internal)
    end

    it "computes its projections from correlation instead of having them authored" do
      status = build_test_worker_status(worker_class: worker_class)
      job = build_test_job(key: 515, bpmn_process_id: "ship-order", worker_status: status)

      call = build_test_call(:complete_job, job: job)

      expect(call.logging_context).to include(job_key: 515, bpmn_process_id: "ship-order",
                                              job_type: "test-worker", rpc: :complete_job)
    end

    it "correlates a fetch call to the worker with no job in scope" do
      status = build_test_worker_status(worker_class: worker_class)

      call = build_test_call(:activate_jobs, worker_status: status)

      expect(call.worker_status).to eq(status)
      expect(call.job).to be_nil
      expect(call.context_tags).not_to include(:job_key)
    end
  end
end
