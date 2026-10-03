# frozen_string_literal: true

require "busybee/testing"

RSpec.describe Busybee::Testing::Runner do
  let(:worker_class) do
    Class.new(Busybee::Worker) do
      job_type "test-worker"
      strict_outputs false

      def perform = { status: "done" }
    end
  end
  let(:client) { build_test_client }
  let(:fired) { [] }

  around do |example|
    with_isolated_hooks do
      observe_every_moment
      example.run
    end
  end

  def around_types = %i[around_perform around_job_execution around_call]

  def observe_every_moment
    (Busybee::Hooks::HOOK_TYPES - around_types).each do |type|
      Busybee::Hooks.register(type, ->(carrier) { fired << [type, carrier] })
    end
    around_types.each do |type|
      Busybee::Hooks.register(type, lambda { |carrier, continue|
        fired << [type, carrier]
        continue.call
      })
    end
  end

  def moments = fired.map(&:first)
  def job_on_client(**) = build_test_job(type: "test-worker", client: client, **)

  describe "build_test_worker" do
    it "builds without firing anything, and is not running" do
      worker = build_test_worker(worker_class, client: client)

      expect(worker).to be_a(described_class)
      expect(worker).not_to be_running
      expect(fired).to be_empty
    end

    it "hands back the client it was built on" do
      expect(build_test_worker(worker_class, client: client).client).to be(client)
    end
  end

  describe "#start" do
    it "fires on_worker_started once, carrying a status of this worker" do
      worker = build_test_worker(worker_class, client: client).start

      expect(worker).to be_running
      expect(moments).to eq([:on_worker_started])
      expect(fired.last.last).to have_attributes(worker_class: worker_class, worker_mode: nil)
    end

    it "refuses to restart a stopped worker" do
      worker = start_test_worker(worker_class, client: client)
      worker.stop!
      fired.clear

      expect { worker.start }.to raise_error(ArgumentError, /stopped/)
      expect(fired).to be_empty
    end
  end

  describe "start_test_worker" do
    it "builds and starts in one step" do
      worker = start_test_worker(worker_class, client: client)

      expect(worker).to be_running
      expect(moments).to eq([:on_worker_started])
    end
  end

  describe "#activate" do
    let(:worker) { start_test_worker(worker_class, client: client) }

    before { worker && fired.clear }

    it "runs each job through the whole job lifecycle, calls included, and no worker moment" do
      job = job_on_client

      worker.activate([job])

      expect(moments).to eq(%i[on_job_activated around_job_execution before_perform around_perform
                               before_call around_call after_call after_perform on_job_executed])
      expect(job).to be_complete
      expect(client.received(:complete_job).map(&:jobKey)).to eq([job.key])
    end

    it "runs the jobs in order and hands them back" do
      jobs = [job_on_client, job_on_client]

      expect(worker.activate(jobs)).to eq(jobs)
      expect(client.received(:complete_job).map(&:jobKey)).to eq(jobs.map(&:key))
    end

    it "activates with no transport: no source, and a status with no worker mode" do
      job = job_on_client

      worker.activate([job])

      expect(job.source).to be_nil
      expect(job.worker_status.worker_mode).to be_nil
    end

    it "refuses a job resolving through a different client, naming the fix" do
      stray = build_test_job(type: "test-worker")

      expect { worker.activate([stray]) }.to raise_error(ArgumentError, /build_test_job\(client: worker.client\)/)
      expect(fired).to be_empty
    end

    it "refuses a job that already resolved" do
      expect { worker.activate([job_on_client(status: :complete)]) }.to raise_error(ArgumentError, /resolved/)
    end

    it "refuses a job that already ran, even one left unresolved" do
      client.on(:complete_job) { raise GRPC::Unavailable, "broker unreachable" }
      job = job_on_client
      worker.activate([job])
      expect(job).to be_ready

      expect { worker.activate([job_on_client, job]) }.to raise_error(ArgumentError, /already ran/)
    end

    it "refuses to run before the worker starts" do
      unstarted = build_test_worker(worker_class, client: client)

      expect { unstarted.activate([job_on_client]) }.to raise_error(ArgumentError, /start/)
    end

    context "when a job's worker declares itself down" do
      let(:worker_class) do
        Class.new(Busybee::Worker) do
          job_type "test-worker"
          shutdown_on IOError

          def perform = raise(IOError, "disk gone")
        end
      end

      it "hands the rest back, tears down on that error, and raises it" do
        doomed = job_on_client
        spared = job_on_client

        expect { worker.activate([doomed, spared]) }.to raise_error(Busybee::Worker::Shutdown)

        spared_moments = fired.select { |_, carrier| carrier.equal?(spared) }.map(&:first)
        expect(spared_moments).to eq(%i[on_job_activated on_job_not_executed])
        closing = %i[on_worker_stop_requested on_job_not_executed on_worker_stopping on_worker_shutdown]
        expect(closing.map { |moment| moments.index(moment) }).to eq(closing.map { |m| moments.index(m) }.sort)
        expect(client.received(:fail_job).map(&:jobKey)).to include(spared.key)
        expect(fired.last.last).to have_attributes(reason: :unhealthy, error: be_a(IOError))
        expect(worker).not_to be_running
      end
    end

    context "when something escapes the job entirely" do
      let(:worker_class) do
        Class.new(Busybee::Worker) do
          job_type "test-worker"

          def perform = raise(Interrupt)
        end
      end

      it "tears down as a crash and lets it propagate" do
        expect { worker.activate([job_on_client]) }.to raise_error(Interrupt)

        expect(moments.last(2)).to eq(%i[on_worker_stopping on_worker_shutdown])
        expect(fired.last.last).to have_attributes(reason: :crash)
        expect(worker).not_to be_running
      end
    end
  end

  describe "#stop!" do
    it "fires the three closing moments in order and stops running" do
      worker = start_test_worker(worker_class, client: client)
      fired.clear

      worker.stop!

      expect(moments).to eq(%i[on_worker_stop_requested on_worker_stopping on_worker_shutdown])
      expect(fired.last.last).to have_attributes(reason: :signal)
      expect(worker).not_to be_running
    end

    it "fires nothing a second time" do
      worker = start_test_worker(worker_class, client: client)
      worker.stop!
      fired.clear

      worker.stop!

      expect(fired).to be_empty
    end
  end

  describe "#status" do
    it "is a real snapshot of this worker as of now, and fires nothing" do
      worker = start_test_worker(worker_class, client: client)
      fired.clear

      status = worker.status

      expect(status).to be_a(Busybee::Worker::Status)
      expect(status).to have_attributes(worker_class: worker_class, worker_mode: nil, reason: nil,
                                        started_at: be_a(Time), shutdown_at: nil)
      expect(fired).to be_empty
    end

    it "carries what the run has done by the time it is taken" do
      worker = start_test_worker(worker_class, client: client)
      worker.activate([job_on_client])
      worker.stop!

      expect(worker.status).to have_attributes(total_job_count: 1, reason: :signal, shutdown_at: be_a(Time))
    end
  end

  describe "#run!" do
    it "refuses before anything fires, pointing at start and stop!" do
      worker = build_test_worker(worker_class, client: client)

      expect { worker.run! }.to raise_error(NotImplementedError, /start.*stop!/)
      expect(fired).to be_empty
    end
  end
end
