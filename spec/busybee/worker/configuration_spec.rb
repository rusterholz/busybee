# frozen_string_literal: true

RSpec.describe Busybee::Worker::Configuration do
  # Helper to create a Configuration for a stub-const'd worker class
  def configuration_for(class_name)
    klass = stub_const(class_name, Class.new)
    described_class.new(klass)
  end

  describe "#job_type" do
    context "with default derivation from class name" do
      it "strips trailing Worker and underscores the remainder" do
        config = configuration_for("ProcessOrderWorker")
        expect(config.job_type).to eq("process_order")
      end

      it "uses only the last :: segment" do
        config = configuration_for("MyApp::Payments::RefundWorker")
        expect(config.job_type).to eq("refund")
      end

      it "underscores multi-word names without Worker suffix" do
        config = configuration_for("MyApp::SimpleTask")
        expect(config.job_type).to eq("simple_task")
      end

      it "handles a single-word class name without Worker suffix" do
        config = configuration_for("Notifier")
        expect(config.job_type).to eq("notifier")
      end

      it "handles a class named exactly Worker" do
        config = configuration_for("Worker")
        expect(config.job_type).to eq("worker")
      end

      it "handles acronym-style names" do
        config = configuration_for("HTTPSyncWorker")
        expect(config.job_type).to eq("http_sync")
      end
    end

    context "with explicit override" do
      it "accepts a string" do
        config = configuration_for("ProcessOrderWorker")
        config.job_type = "custom-type"
        expect(config.job_type).to eq("custom-type")
      end

      it "converts symbols to strings" do
        config = configuration_for("ProcessOrderWorker")
        config.job_type = :custom_type
        expect(config.job_type).to eq("custom_type")
      end
    end
  end

  describe "#description" do
    it "defaults to nil" do
      config = configuration_for("ProcessOrderWorker")
      expect(config.description).to be_nil
    end

    it "stores a description string" do
      config = configuration_for("ProcessOrderWorker")
      config.description = "Processes incoming orders"
      expect(config.description).to eq("Processes incoming orders")
    end
  end

  describe "#inputs" do
    it "starts as an empty collection" do
      config = configuration_for("ProcessOrderWorker")
      expect(config.inputs).to eq([])
    end
  end

  describe "#outputs" do
    it "starts as an empty collection" do
      config = configuration_for("ProcessOrderWorker")
      expect(config.outputs).to eq([])
    end
  end

  describe "#add_input" do
    let(:config) { configuration_for("TestWorker") }

    def build_input(**overrides)
      described_class::Input.new(
        name: :order_id, source: [:variable], required: true, type: nil,
        description: nil, default: nil, accessor_name: nil, define_accessor: true,
        **overrides
      )
    end

    it "adds input to the collection" do
      config.add_input(build_input)
      expect(config.inputs.length).to eq(1)
      expect(config.inputs.first.name).to eq(:order_id)
    end

    it "raises on nil name" do
      expect { config.add_input(build_input(name: nil)) }.to raise_error(
        Busybee::InvalidWorkerDefinition, /Name is required/
      )
    end

    it "raises on blank name" do
      expect { config.add_input(build_input(name: :"")) }.to raise_error(
        Busybee::InvalidWorkerDefinition, /Name is required/
      )
    end

    it "raises on empty source" do
      expect { config.add_input(build_input(source: [])) }.to raise_error(
        Busybee::InvalidWorkerDefinition, /source:.*required/
      )
    end

    it "raises on invalid source" do
      expect { config.add_input(build_input(source: [:database])) }.to raise_error(
        Busybee::InvalidWorkerDefinition, /Invalid source.*:database/
      )
    end

    it "raises on invalid type" do
      expect { config.add_input(build_input(type: :array)) }.to raise_error(
        Busybee::InvalidWorkerDefinition, /Invalid type.*:array/
      )
    end

    it "accepts all valid types" do
      described_class::VALID_TYPES.each_with_index do |type, i|
        expect { config.add_input(build_input(name: :"field_#{i}", type: type.to_sym)) }.not_to raise_error
      end
    end

    it "raises on duplicate input names" do
      config.add_input(build_input)
      expect { config.add_input(build_input) }.to raise_error(
        Busybee::InvalidWorkerDefinition, /Input :order_id is already declared/
      )
    end

    it "deduplicates sources" do
      input = build_input(source: %i[variable variable])
      config.add_input(input)
      expect(config.inputs.first.source).to eq([:variable])
    end

    it "raises when define_accessor: false is combined with accessor_name" do
      expect { config.add_input(build_input(define_accessor: false, accessor_name: :oid)) }.to raise_error(
        Busybee::InvalidWorkerDefinition, /define_accessor: false.*accessor_name:.*mutually exclusive/
      )
    end
  end

  describe "#add_output" do
    let(:config) { configuration_for("TestWorker") }

    def build_output(**overrides)
      described_class::Output.new(name: :result, required: true, type: nil, description: nil, **overrides)
    end

    it "adds output to the collection" do
      config.add_output(build_output)
      expect(config.outputs.length).to eq(1)
      expect(config.outputs.first.name).to eq(:result)
    end

    it "raises on nil name" do
      expect { config.add_output(build_output(name: nil)) }.to raise_error(
        Busybee::InvalidWorkerDefinition, /Name is required/
      )
    end

    it "raises on invalid type" do
      expect { config.add_output(build_output(type: :hash)) }.to raise_error(
        Busybee::InvalidWorkerDefinition, /Invalid type.*:hash/
      )
    end

    it "raises on duplicate output names" do
      config.add_output(build_output)
      expect { config.add_output(build_output) }.to raise_error(
        Busybee::InvalidWorkerDefinition, /Output :result is already declared/
      )
    end
  end

  describe "#worker_mode=" do
    let(:config) { configuration_for("TestWorker") }

    it "accepts valid modes" do
      %i[polling streaming hybrid].each do |mode|
        config.worker_mode = mode
        expect(config.worker_mode).to eq(mode)
      end
    end

    it "raises on invalid mode" do
      expect { config.worker_mode = :batch }.to raise_error(
        Busybee::InvalidWorkerDefinition, /Invalid worker mode/
      )
    end
  end

  describe "#polling_config=" do
    let(:config) { configuration_for("TestWorker") }

    it "accepts valid kwargs" do
      config.polling_config = { max_jobs: 10, request_timeout: 30_000 }
      expect(config.polling_config).to eq(max_jobs: 10, request_timeout: 30_000)
    end

    it "raises on unknown kwargs" do
      expect { config.polling_config = { batch_size: 10 } }.to raise_error(
        Busybee::InvalidWorkerDefinition, /Unknown polling config.*:batch_size/
      )
    end
  end

  describe "#streaming_config=" do
    let(:config) { configuration_for("TestWorker") }

    it "accepts queue: true" do
      config.streaming_config = { queue: true }
      expect(config.streaming_config).to eq(queue: true)
    end

    it "accepts queue: false" do
      config.streaming_config = { queue: false }
      expect(config.streaming_config).to eq(queue: false)
    end

    it "raises on unknown kwargs" do
      expect { config.streaming_config = { buffer_size: 100 } }.to raise_error(
        Busybee::InvalidWorkerDefinition, /Unknown streaming config.*:buffer_size/
      )
    end

    it "raises when queue: is non-boolean" do
      expect { config.streaming_config = { queue: :yes } }.to raise_error(
        Busybee::InvalidWorkerDefinition, /`queue:` requires a boolean/
      )
    end

    it "raises when queue_throttle: is set with queue: false" do
      expect { config.streaming_config = { queue: false, queue_throttle: 5 } }.to raise_error(
        Busybee::InvalidWorkerDefinition, /`queue_throttle:` cannot be set when `queue: false`/
      )
    end

    it "accepts queue_throttle: with an integer" do
      config.streaming_config = { queue_throttle: 5 }
      expect(config.streaming_config).to eq(queue_throttle: 5)
    end

    it "accepts queue_throttle: 0 (minimal throttle)" do
      config.streaming_config = { queue_throttle: 0 }
      expect(config.streaming_config).to eq(queue_throttle: 0)
    end

    it "accepts queue_throttle: with a float" do
      config.streaming_config = { queue_throttle: 0.5 }
      expect(config.streaming_config).to eq(queue_throttle: 0.5)
    end

    it "accepts queue_throttle: with a Rational" do
      config.streaming_config = { queue_throttle: Rational(87, 1000) }
      expect(config.streaming_config).to eq(queue_throttle: Rational(87, 1000))
    end

    it "coerces queue_throttle: true to 0 (minimal throttle)" do
      config.streaming_config = { queue_throttle: true }
      expect(config.streaming_config).to eq(queue_throttle: 0)
    end

    it "coerces queue_throttle: nil to false (no throttling)" do
      config.streaming_config = { queue_throttle: nil }
      expect(config.streaming_config).to eq(queue_throttle: false)
    end

    it "raises when queue_throttle: is negative" do
      expect { config.streaming_config = { queue_throttle: -1 } }.to raise_error(
        Busybee::InvalidWorkerDefinition, /`queue_throttle:` must be a non-negative Numeric/
      )
    end

    it "raises when queue_throttle: is non-Numeric" do
      expect { config.streaming_config = { queue_throttle: "5" } }.to raise_error(
        Busybee::InvalidWorkerDefinition, /`queue_throttle:` must be a non-negative Numeric/
      )
    end
  end

  describe "#queue_throttle" do
    let(:config) { configuration_for("TestWorker") }

    it "defaults to false (no throttling) when neither DSL nor gem-level sets it" do
      expect(config.queue_throttle).to be(false)
    end

    it "returns the DSL value when set in streaming config" do
      config.streaming_config = { queue_throttle: 0.5 }
      expect(config.queue_throttle).to eq(0.5)
    end

    it "returns 0 when explicitly set (minimal throttle)" do
      config.streaming_config = { queue_throttle: 0 }
      expect(config.queue_throttle).to eq(0)
    end

    it "falls back to gem-level default_queue_throttle" do
      allow(Busybee).to receive(:default_queue_throttle).and_return(2)
      expect(config.queue_throttle).to eq(2)
    end
  end

  describe "#queue_enabled?" do
    let(:config) { configuration_for("TestWorker") }

    it "defaults to true when no streaming config is set" do
      expect(config.queue_enabled?).to be(true)
    end

    it "returns true when streaming config has queue: true" do
      config.streaming_config = { queue: true }
      expect(config.queue_enabled?).to be(true)
    end

    it "returns false when streaming config has queue: false" do
      config.streaming_config = { queue: false }
      expect(config.queue_enabled?).to be(false)
    end
  end

  describe "#polling_options" do
    let(:config) { configuration_for("TestWorker") }

    it "returns gem defaults when no DSL config is set" do
      opts = config.polling_options
      expect(opts[:max_jobs]).to eq(Busybee::Defaults::DEFAULT_MAX_JOBS)
      expect(opts[:request_timeout]).to eq(Busybee.default_job_request_timeout)
      expect(opts[:job_timeout]).to eq(Busybee.default_job_lock_timeout)
    end

    it "uses DSL polling_config values when set" do
      config.polling_config = { max_jobs: 10, request_timeout: 30_000 }
      opts = config.polling_options
      expect(opts[:max_jobs]).to eq(10)
      expect(opts[:request_timeout]).to eq(30_000)
    end

    it "uses DSL job_timeout when set" do
      config.job_timeout = 120_000
      expect(config.polling_options[:job_timeout]).to eq(120_000)
    end

    it "merges DSL overrides with gem defaults" do
      config.polling_config = { max_jobs: 5 }
      opts = config.polling_options
      expect(opts[:max_jobs]).to eq(5)
      expect(opts[:request_timeout]).to eq(Busybee.default_job_request_timeout)
      expect(opts[:job_timeout]).to eq(Busybee.default_job_lock_timeout)
    end
  end

  describe "#streaming_options" do
    let(:config) { configuration_for("TestWorker") }

    it "returns gem default job_timeout when no DSL config is set" do
      expect(config.streaming_options).to eq(job_timeout: Busybee.default_job_lock_timeout)
    end

    it "uses DSL job_timeout when set" do
      config.job_timeout = 120_000
      expect(config.streaming_options[:job_timeout]).to eq(120_000)
    end
  end

  describe "#job_timeout=" do
    let(:config) { configuration_for("TestWorker") }

    it "accepts an Integer" do
      config.job_timeout = 300_000
      expect(config.job_timeout).to eq(300_000)
    end

    it "raises on non-Integer, non-Duration" do
      expect { config.job_timeout = "5 minutes" }.to raise_error(
        Busybee::InvalidWorkerDefinition, /job_timeout.*Integer.*ActiveSupport::Duration/
      )
    end
  end

  describe "#backoff=" do
    let(:config) { configuration_for("TestWorker") }

    it "accepts an Integer" do
      config.backoff = 30_000
      expect(config.backoff).to eq(30_000)
    end

    it "raises on non-Integer, non-Duration" do
      expect { config.backoff = 30.5 }.to raise_error(
        Busybee::InvalidWorkerDefinition, /backoff.*Integer.*ActiveSupport::Duration/
      )
    end
  end

  describe "#backpressure_delay=" do
    let(:config) { configuration_for("TestWorker") }

    it "defaults to nil" do
      expect(config.backpressure_delay).to be_nil
    end

    it "accepts an Integer" do
      config.backpressure_delay = 10_000
      expect(config.backpressure_delay).to eq(10_000)
    end

    it "raises on non-Integer, non-Duration" do
      expect { config.backpressure_delay = "5 seconds" }.to raise_error(
        Busybee::InvalidWorkerDefinition, /backpressure_delay.*Integer.*ActiveSupport::Duration/
      )
    end
  end

  describe Busybee::Worker::Configuration::Input do
    subject(:input) do
      described_class.new(
        name: :order_id,
        source: :variable,
        required: true,
        type: :uuid,
        description: "The order identifier",
        default: nil,
        accessor_name: nil,
        define_accessor: true
      )
    end

    it "stores core attributes" do
      expect(input.name).to eq(:order_id)
      expect(input.source).to eq(:variable)
      expect(input.required).to be(true)
      expect(input.type).to eq(:uuid)
      expect(input.description).to eq("The order identifier")
    end

    it "stores accessor options" do
      expect(input.default).to be_nil
      expect(input.accessor_name).to be_nil
      expect(input.define_accessor).to be(true)
    end

    it "supports multi-source inputs" do
      multi_input = described_class.new(
        name: :channel,
        source: %i[header variable],
        required: false,
        type: :string,
        description: nil,
        default: "email",
        accessor_name: nil,
        define_accessor: true
      )

      expect(multi_input.source).to eq(%i[header variable])
      expect(multi_input.default).to eq("email")
    end
  end

  describe Busybee::Worker::Configuration::Output do
    it "stores all output attributes" do
      output = described_class.new(
        name: :notification_id,
        required: true,
        type: :uuid,
        description: "The notification ID"
      )

      expect(output.name).to eq(:notification_id)
      expect(output.required).to be(true)
      expect(output.type).to eq(:uuid)
      expect(output.description).to eq("The notification ID")
    end
  end

  describe "#to_h" do
    let(:config) do
      configuration_for("ProcessOrderWorker").tap do |c|
        c.description = "Processes orders"
        c.worker_mode = :polling
        c.polling_config = { max_jobs: 10 }
        c.job_timeout = 300_000
        c.backoff = 30_000
        c.backpressure_delay = 10_000
      end
    end

    it "includes metadata" do
      result = config.to_h
      expect(result[:job_type]).to eq("process_order")
      expect(result[:description]).to eq("Processes orders")
      expect(result[:inputs]).to eq([])
      expect(result[:outputs]).to eq([])
    end

    it "includes runner configuration" do
      result = config.to_h
      expect(result[:worker_mode]).to eq(:polling)
      expect(result[:polling_config]).to eq(max_jobs: 10)
      expect(result[:streaming_config]).to eq({})
      expect(result[:job_timeout]).to eq(300_000)
      expect(result[:backoff]).to eq(30_000)
      expect(result[:backpressure_delay]).to eq(10_000)
    end

    it "includes lifecycle defaults" do
      result = config.to_h
      expect(result[:complete_job_on_success]).to be(true)
      expect(result[:fail_job_on_error]).to be(true)
      expect(result[:shutdown_on]).to eq([])
    end

    it "includes lifecycle configuration when overridden" do
      config.complete_job_on_success = false
      config.fail_job_on_error = false
      config.add_shutdown_on(RuntimeError)

      result = config.to_h
      expect(result[:complete_job_on_success]).to be(false)
      expect(result[:fail_job_on_error]).to be(false)
      expect(result[:shutdown_on]).to eq([RuntimeError])
    end
  end

  describe "#complete_job_on_success" do
    let(:config) { configuration_for("TestWorker") }

    it "defaults to true" do
      expect(config.complete_job_on_success).to be(true)
    end

    it "accepts true" do
      config.complete_job_on_success = true
      expect(config.complete_job_on_success).to be(true)
    end

    it "accepts false" do
      config.complete_job_on_success = false
      expect(config.complete_job_on_success).to be(false)
    end

    it "raises on non-boolean" do
      expect { config.complete_job_on_success = :yes }.to raise_error(
        Busybee::InvalidWorkerDefinition, /complete_job_on_success.*boolean/
      )
    end
  end

  describe "#fail_job_on_error" do
    let(:config) { configuration_for("TestWorker") }

    it "defaults to true" do
      expect(config.fail_job_on_error).to be(true)
    end

    it "accepts true" do
      config.fail_job_on_error = true
      expect(config.fail_job_on_error).to be(true)
    end

    it "accepts false" do
      config.fail_job_on_error = false
      expect(config.fail_job_on_error).to be(false)
    end

    it "raises on non-boolean" do
      expect { config.fail_job_on_error = "true" }.to raise_error(
        Busybee::InvalidWorkerDefinition, /fail_job_on_error.*boolean/
      )
    end
  end

  describe "#add_shutdown_on" do
    let(:config) { configuration_for("TestWorker") }

    it "starts with an empty array" do
      expect(config.shutdown_on).to eq([])
    end

    it "adds an exception class" do
      config.add_shutdown_on(RuntimeError)
      expect(config.shutdown_on).to eq([RuntimeError])
    end

    it "accepts multiple classes via splat" do
      config.add_shutdown_on(RuntimeError, ArgumentError)
      expect(config.shutdown_on).to contain_exactly(RuntimeError, ArgumentError)
    end

    it "is additive across calls" do
      config.add_shutdown_on(RuntimeError)
      config.add_shutdown_on(ArgumentError)
      expect(config.shutdown_on).to contain_exactly(RuntimeError, ArgumentError)
    end

    it "deduplicates" do
      config.add_shutdown_on(RuntimeError)
      config.add_shutdown_on(RuntimeError, ArgumentError)
      expect(config.shutdown_on).to contain_exactly(RuntimeError, ArgumentError)
    end

    it "raises on non-class argument" do
      expect { config.add_shutdown_on("RuntimeError") }.to raise_error(
        Busybee::InvalidWorkerDefinition, /shutdown_on.*exception classes/
      )
    end

    it "raises on class that is not an Exception subclass" do
      expect { config.add_shutdown_on(String) }.to raise_error(
        Busybee::InvalidWorkerDefinition, /shutdown_on.*exception classes/
      )
    end
  end
end
