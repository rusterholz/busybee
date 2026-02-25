# frozen_string_literal: true

RSpec.describe Busybee::RuntimeConfig do
  let(:worker_class) do
    Class.new(Busybee::Worker) do
      job_type "test_worker"
      def perform; end
    end
  end

  before { stub_const("TestWorker", worker_class) }

  # Save/restore gem-level config that tests may modify
  around do |example|
    saved = %i[
      @default_runner_mode @runner_backpressure_delay @default_queue_throttle
      @log_format @worker_name @cluster_address
    ].to_h { |ivar| [ivar, Busybee.instance_variable_get(ivar)] }
    example.run
  ensure
    saved.each { |ivar, val| Busybee.instance_variable_set(ivar, val) }
  end

  describe "#initialize" do
    it "accepts runner_mode" do
      config = described_class.new(runner_mode: :polling)
      expect(config.runner_mode).to eq(:polling)
    end

    it "defaults runner_mode to nil" do
      config = described_class.new
      expect(config.runner_mode).to be_nil
    end

    it "accepts runner-scoped fields" do
      config = described_class.new(
        backpressure_delay: 3000,
        max_jobs: 10,
        request_timeout: 30_000,
        queue_throttle: 500
      )
      expect(config).to have_attributes(
        backpressure_delay: 3000,
        max_jobs: 10,
        request_timeout: 30_000,
        queue_throttle: 500
      )
    end

    it "accepts process-wide fields" do
      config = described_class.new(
        log_format: :json,
        worker_name: "my-worker",
        cluster_address: "zeebe.example.com:26500"
      )
      expect(config).to have_attributes(
        log_format: :json,
        worker_name: "my-worker",
        cluster_address: "zeebe.example.com:26500"
      )
    end

    it "defaults all fields to nil" do
      config = described_class.new
      expect(config).to have_attributes(
        runner_mode: nil,
        backpressure_delay: nil,
        max_jobs: nil,
        request_timeout: nil,
        queue_enabled: nil,
        queue_throttle: nil,
        job_timeout: nil,
        backoff: nil,
        log_format: nil,
        worker_name: nil,
        cluster_address: nil
      )
    end

    it "accepts per-worker overrides" do
      config = described_class.new(
        runner_mode: :hybrid,
        workers: { "TestWorker" => { runner_mode: :polling, max_jobs: 5 } }
      )
      expect(config.runner_mode).to eq(:hybrid)
    end

    it "validates runner_mode" do
      expect { described_class.new(runner_mode: :invalid) }.
        to raise_error(ArgumentError, /Invalid runner mode.*:invalid/)
    end

    it "validates per-worker runner_mode" do
      expect { described_class.new(workers: { "TestWorker" => { runner_mode: :bogus } }) }.
        to raise_error(ArgumentError, /Invalid runner mode.*:bogus/)
    end
  end

  describe "#resolve_for" do
    it "returns a RuntimeConfig" do
      config = described_class.new(runner_mode: :polling)
      resolved = config.resolve_for(worker_class)
      expect(resolved).to be_a(described_class)
    end

    context "with runner_mode precedence" do
      it "uses per-worker override over global override" do
        config = described_class.new(
          runner_mode: :hybrid,
          workers: { "TestWorker" => { runner_mode: :polling } }
        )
        expect(config.resolve_for(worker_class).runner_mode).to eq(:polling)
      end

      it "uses global override when no per-worker override" do
        config = described_class.new(runner_mode: :hybrid)
        expect(config.resolve_for(worker_class).runner_mode).to eq(:hybrid)
      end

      it "falls back to worker DSL when no RuntimeConfig override" do
        worker_class.runner_mode :streaming
        config = described_class.new
        expect(config.resolve_for(worker_class).runner_mode).to eq(:streaming)
      end

      it "falls back to gem default when no other source" do
        Busybee.default_runner_mode = :polling
        config = described_class.new
        expect(config.resolve_for(worker_class).runner_mode).to eq(:polling)
      end

      it "prefers per-worker RuntimeConfig over worker DSL" do
        worker_class.runner_mode :streaming
        config = described_class.new(
          workers: { "TestWorker" => { runner_mode: :polling } }
        )
        expect(config.resolve_for(worker_class).runner_mode).to eq(:polling)
      end

      it "prefers global RuntimeConfig over worker DSL" do
        worker_class.runner_mode :streaming
        config = described_class.new(runner_mode: :hybrid)
        expect(config.resolve_for(worker_class).runner_mode).to eq(:hybrid)
      end
    end

    context "with backpressure_delay precedence (4-level: RC per-worker → RC global → DSL → gem)" do
      it "uses per-worker override" do
        worker_class.backpressure_delay 8000
        config = described_class.new(
          backpressure_delay: 6000,
          workers: { "TestWorker" => { backpressure_delay: 2000 } }
        )
        expect(config.resolve_for(worker_class).backpressure_delay).to eq(2000)
      end

      it "uses global RC override" do
        config = described_class.new(backpressure_delay: 6000)
        expect(config.resolve_for(worker_class).backpressure_delay).to eq(6000)
      end

      it "falls back to worker DSL" do
        worker_class.backpressure_delay 8000
        config = described_class.new
        expect(config.resolve_for(worker_class).backpressure_delay).to eq(8000)
      end

      it "falls back to gem default" do
        config = described_class.new
        expect(config.resolve_for(worker_class).backpressure_delay).to eq(
          Busybee::Defaults::DEFAULT_RUNNER_BACKPRESSURE_DELAY_MS
        )
      end
    end

    context "with max_jobs precedence (4-level: RC per-worker → RC global → DSL → gem)" do
      it "uses per-worker override" do
        config = described_class.new(
          max_jobs: 50,
          workers: { "TestWorker" => { max_jobs: 10 } }
        )
        expect(config.resolve_for(worker_class).max_jobs).to eq(10)
      end

      it "uses global RC override" do
        config = described_class.new(max_jobs: 50)
        expect(config.resolve_for(worker_class).max_jobs).to eq(50)
      end

      it "falls back to worker DSL" do
        worker_class.polling max_jobs: 15
        config = described_class.new
        expect(config.resolve_for(worker_class).max_jobs).to eq(15)
      end

      it "falls back to gem default" do
        config = described_class.new
        expect(config.resolve_for(worker_class).max_jobs).to eq(
          Busybee.default_max_jobs
        )
      end
    end

    context "with request_timeout precedence" do
      it "uses per-worker override over global" do
        config = described_class.new(
          request_timeout: 90_000,
          workers: { "TestWorker" => { request_timeout: 15_000 } }
        )
        expect(config.resolve_for(worker_class).request_timeout).to eq(15_000)
      end

      it "falls back to worker DSL" do
        worker_class.polling request_timeout: 45_000
        config = described_class.new
        expect(config.resolve_for(worker_class).request_timeout).to eq(45_000)
      end

      it "falls back to gem default" do
        config = described_class.new
        expect(config.resolve_for(worker_class).request_timeout).to eq(
          Busybee.default_job_request_timeout
        )
      end
    end

    context "with queue_throttle precedence" do
      it "uses per-worker override" do
        config = described_class.new(
          queue_throttle: 200,
          workers: { "TestWorker" => { queue_throttle: 50 } }
        )
        expect(config.resolve_for(worker_class).queue_throttle).to eq(50)
      end

      it "falls back to worker DSL" do
        worker_class.streaming queue_throttle: 100
        config = described_class.new
        expect(config.resolve_for(worker_class).queue_throttle).to eq(100)
      end

      it "falls back to gem default (false)" do
        config = described_class.new
        expect(config.resolve_for(worker_class).queue_throttle).to be(false)
      end
    end

    context "with job_timeout precedence (YAML-only, no CLI flag)" do
      it "falls back to worker DSL" do
        worker_class.job_timeout 120_000
        config = described_class.new
        expect(config.resolve_for(worker_class).job_timeout).to eq(120_000)
      end

      it "falls back to gem default" do
        config = described_class.new
        expect(config.resolve_for(worker_class).job_timeout).to eq(
          Busybee::Defaults::DEFAULT_JOB_LOCK_TIMEOUT_MS
        )
      end

      it "allows per-worker override (for YAML)" do
        worker_class.job_timeout 120_000
        config = described_class.new(
          workers: { "TestWorker" => { job_timeout: 30_000 } }
        )
        expect(config.resolve_for(worker_class).job_timeout).to eq(30_000)
      end
    end

    context "with backoff precedence" do
      it "uses per-worker override" do
        worker_class.backoff 60_000
        config = described_class.new(
          backoff: 30_000,
          workers: { "TestWorker" => { backoff: 10_000 } }
        )
        expect(config.resolve_for(worker_class).backoff).to eq(10_000)
      end

      it "falls back to worker DSL" do
        worker_class.backoff 60_000
        config = described_class.new
        expect(config.resolve_for(worker_class).backoff).to eq(60_000)
      end

      it "falls back to gem default" do
        config = described_class.new
        expect(config.resolve_for(worker_class).backoff).to eq(
          Busybee.default_fail_job_backoff
        )
      end
    end

    context "with queue_enabled precedence" do
      it "uses per-worker override" do
        config = described_class.new(
          workers: { "TestWorker" => { queue_enabled: false } }
        )
        expect(config.resolve_for(worker_class).queue_enabled).to be(false)
      end

      it "falls back to worker DSL" do
        worker_class.streaming queue: false
        config = described_class.new
        expect(config.resolve_for(worker_class).queue_enabled).to be(false)
      end

      it "falls back to gem default (true)" do
        config = described_class.new
        expect(config.resolve_for(worker_class).queue_enabled).to be(true)
      end
    end

    context "with first_non_nil semantics" do
      it "treats 0 as an explicit value (not nil)" do
        config = described_class.new(
          backpressure_delay: 0,
          workers: { "TestWorker" => { backpressure_delay: 0 } }
        )
        expect(config.resolve_for(worker_class).backpressure_delay).to eq(0)
      end

      it "treats false as an explicit value for queue_throttle" do
        worker_class.streaming queue_throttle: 100
        config = described_class.new(
          workers: { "TestWorker" => { queue_throttle: false } }
        )
        expect(config.resolve_for(worker_class).queue_throttle).to be(false)
      end
    end

    context "with process-wide fields (no per-worker overrides)" do
      it "resolves log_format from global RC" do
        config = described_class.new(log_format: :json)
        expect(config.resolve_for(worker_class).log_format).to eq(:json)
      end

      it "resolves log_format from gem default" do
        config = described_class.new
        expect(config.resolve_for(worker_class).log_format).to eq(:text)
      end

      it "resolves worker_name from global RC" do
        config = described_class.new(worker_name: "my-worker")
        expect(config.resolve_for(worker_class).worker_name).to eq("my-worker")
      end

      it "resolves worker_name from gem default" do
        Busybee.instance_variable_set(:@worker_name, nil)
        config = described_class.new
        # Busybee.worker_name falls back to Socket.gethostname
        expect(config.resolve_for(worker_class).worker_name).to eq(Busybee.worker_name)
      end

      it "resolves cluster_address from global RC" do
        config = described_class.new(cluster_address: "zeebe.example.com:26500")
        expect(config.resolve_for(worker_class).cluster_address).to eq("zeebe.example.com:26500")
      end

      it "resolves cluster_address from gem default" do
        config = described_class.new
        expect(config.resolve_for(worker_class).cluster_address).to eq(Busybee.cluster_address)
      end
    end

    it "handles worker with no per-worker override" do
      other_worker = Class.new(Busybee::Worker) do
        job_type "other"
        def perform; end
      end
      stub_const("OtherWorker", other_worker)

      config = described_class.new(
        runner_mode: :hybrid,
        max_jobs: 50,
        workers: { "TestWorker" => { runner_mode: :polling, max_jobs: 10 } }
      )
      resolved = config.resolve_for(other_worker)
      expect(resolved).to have_attributes(runner_mode: :hybrid, max_jobs: 50)
    end
  end

  describe "#polling_options" do
    it "returns max_jobs, request_timeout, and job_timeout" do
      config = described_class.new(max_jobs: 10, request_timeout: 30_000, job_timeout: 90_000)
      expect(config.polling_options).to eq(max_jobs: 10, request_timeout: 30_000, job_timeout: 90_000)
    end

    it "returns nil values when not set" do
      config = described_class.new
      expect(config.polling_options).to eq(max_jobs: nil, request_timeout: nil, job_timeout: nil)
    end

    it "returns populated values after resolve_for" do
      config = described_class.new
      resolved = config.resolve_for(worker_class)
      expect(resolved.polling_options).to eq(
        max_jobs: Busybee.default_max_jobs,
        request_timeout: Busybee.default_job_request_timeout,
        job_timeout: Busybee.default_job_lock_timeout
      )
    end
  end
end
