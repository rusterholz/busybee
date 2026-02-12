# frozen_string_literal: true

RSpec.describe Busybee::Worker::DSL do
  let(:client) { instance_double(Busybee::Client) }

  let(:raw_job) do
    # rubocop:disable RSpec/VerifiedDoubles
    double(
      "Busybee::GRPC::ActivatedJob",
      key: 123456,
      type: "process_order",
      processInstanceKey: 789012,
      bpmnProcessId: "order-workflow",
      retries: 3,
      deadline: 1640000000000,
      variables: '{"order_id":"abc-123","channel":"sms","tags":["urgent","vip"]}',
      customHeaders: '{"priority":"high","channel":"email"}'
    )
    # rubocop:enable RSpec/VerifiedDoubles
  end

  let(:job) { Busybee::Job.new(raw_job, client: client) }

  describe ".input" do
    it "registers an input on the configuration" do
      worker = stub_const("InputWorker", Class.new(Busybee::Worker) do
        input :order_id, source: :variable
      end)

      inputs = worker.configuration.inputs
      expect(inputs.length).to eq(1)
      expect(inputs.first.name).to eq(:order_id)
      expect(inputs.first.source).to eq([:variable])
    end

    it "accepts all options" do
      worker = stub_const("FullInputWorker", Class.new(Busybee::Worker) do
        input :channel, source: %i[header variable], type: :string,
                        description: "Notification channel", default: "email"
      end)

      input = worker.configuration.inputs.first
      expect(input.source).to eq(%i[header variable])
      expect(input.required).to be(false) # implied by default: being present
      expect(input.type).to eq(:string)
      expect(input.description).to eq("Notification channel")
      expect(input.default).to eq("email")
    end

    it "defaults required to the gem-level default when not passed" do
      worker = stub_const("DefaultRequiredWorker", Class.new(Busybee::Worker) do
        input :order_id, source: :variable
      end)

      expect(worker.configuration.inputs.first.required).to be(true)
    end

    it "sets required to false when default is provided and required not explicitly passed" do
      worker = stub_const("DefaultImpliesOptionalWorker", Class.new(Busybee::Worker) do
        input :channel, source: :variable, default: "email"
      end)

      expect(worker.configuration.inputs.first.required).to be(false)
    end

    it "normalizes a single source to an array" do
      worker = stub_const("SingleSourceWorker", Class.new(Busybee::Worker) do
        input :order_id, source: :variable
      end)

      expect(worker.configuration.inputs.first.source).to eq([:variable])
    end

    it "converts name to a symbol" do
      worker = stub_const("StringNameWorker", Class.new(Busybee::Worker) do
        input "order_id", source: :variable
      end)

      expect(worker.configuration.inputs.first.name).to eq(:order_id)
    end
  end

  describe ".variable" do
    it "is a shortcut for input with source: :variable" do
      worker = stub_const("VariableWorker", Class.new(Busybee::Worker) do
        variable :order_id, type: :uuid
      end)

      input = worker.configuration.inputs.first
      expect(input.name).to eq(:order_id)
      expect(input.source).to eq([:variable])
      expect(input.type).to eq(:uuid)
    end
  end

  describe ".header" do
    it "is a shortcut for input with source: :header" do
      worker = stub_const("HeaderWorker", Class.new(Busybee::Worker) do
        header :priority, type: :string
      end)

      input = worker.configuration.inputs.first
      expect(input.name).to eq(:priority)
      expect(input.source).to eq([:header])
      expect(input.type).to eq(:string)
    end
  end

  describe "input accessors" do
    it "reads from variables" do
      worker = stub_const("VarAccessorWorker", Class.new(Busybee::Worker) do
        variable :order_id
      end)

      instance = worker.new(job)
      expect(instance.order_id).to eq("abc-123")
    end

    it "reads from headers" do
      worker = stub_const("HeaderAccessorWorker", Class.new(Busybee::Worker) do
        header :priority
      end)

      instance = worker.new(job)
      expect(instance.priority).to eq("high")
    end

    it "returns nil for missing values without a default" do
      worker = stub_const("MissingWorker", Class.new(Busybee::Worker) do
        variable :nonexistent
      end)

      instance = worker.new(job)
      expect(instance.nonexistent).to be_nil
    end

    it "returns the default when value is missing" do
      worker = stub_const("DefaultWorker", Class.new(Busybee::Worker) do
        variable :missing_field, default: "fallback"
      end)

      instance = worker.new(job)
      expect(instance.missing_field).to eq("fallback")
    end

    it "clones defaults to prevent shared-state mutation" do
      worker = stub_const("CloneWorker", Class.new(Busybee::Worker) do
        variable :missing_field, default: []
      end)

      instance1 = worker.new(job)
      instance2 = worker.new(job)
      instance1.missing_field << "mutated"

      expect(instance2.missing_field).to eq([])
    end

    it "returns the actual value over the default when present" do
      worker = stub_const("PresentWorker", Class.new(Busybee::Worker) do
        variable :order_id, default: "should-not-see-this"
      end)

      instance = worker.new(job)
      expect(instance.order_id).to eq("abc-123")
    end

    context "with multi-source inputs" do
      it "returns first non-nil in source order" do
        worker = stub_const("MultiSourceWorker", Class.new(Busybee::Worker) do
          input :channel, source: %i[header variable]
        end)

        instance = worker.new(job)
        # "channel" exists in both headers ("email") and variables ("sms"); header is first
        expect(instance.channel).to eq("email")
      end

      it "falls back to second source when first is nil" do
        worker = stub_const("FallbackWorker", Class.new(Busybee::Worker) do
          input :order_id, source: %i[header variable]
        end)

        instance = worker.new(job)
        # "order_id" only exists in variables, not headers
        expect(instance.order_id).to eq("abc-123")
      end
    end

    it "handles Array values without confusing them with internal state" do
      worker = stub_const("ArrayValueWorker", Class.new(Busybee::Worker) do
        variable :tags
      end)

      instance = worker.new(job)
      expect(instance.tags).to eq(%w[urgent vip])
    end

    it "uses accessor_name when provided" do
      worker = stub_const("RenamedWorker", Class.new(Busybee::Worker) do
        variable :order_id, accessor_name: :oid
      end)

      instance = worker.new(job)
      expect(instance.oid).to eq("abc-123")
      expect(instance).not_to respond_to(:order_id)
    end

    it "skips accessor when define_accessor is false" do
      worker = stub_const("NoAccessorWorker", Class.new(Busybee::Worker) do
        variable :order_id, define_accessor: false
      end)

      expect(worker.configuration.inputs.first.name).to eq(:order_id)
      expect(worker.method_defined?(:order_id)).to be(false)
    end
  end

  describe ".output" do
    it "registers an output on the configuration" do
      worker = stub_const("OutputWorker", Class.new(Busybee::Worker) do
        output :notification_id, type: :uuid, description: "The notification ID"
      end)

      outputs = worker.configuration.outputs
      expect(outputs.length).to eq(1)
      expect(outputs.first.name).to eq(:notification_id)
      expect(outputs.first.type).to eq(:uuid)
      expect(outputs.first.description).to eq("The notification ID")
    end

    it "defaults required to the gem-level default" do
      worker = stub_const("DefaultOutputWorker", Class.new(Busybee::Worker) do
        output :result
      end)

      expect(worker.configuration.outputs.first.required).to be(true)
    end

    it "accepts explicit required: false" do
      worker = stub_const("OptionalOutputWorker", Class.new(Busybee::Worker) do
        output :debug_info, required: false
      end)

      expect(worker.configuration.outputs.first.required).to be(false)
    end
  end

  describe ".runner_mode" do
    it "sets runner mode on configuration" do
      worker = stub_const("PollingWorker", Class.new(Busybee::Worker) do
        runner_mode :polling
      end)

      expect(worker.configuration.runner_mode).to eq(:polling)
    end
  end

  describe ".polling" do
    it "sets polling configuration" do
      worker = stub_const("PollingConfigWorker", Class.new(Busybee::Worker) do
        polling max_jobs: 10, request_timeout: 30_000
      end)

      expect(worker.configuration.polling_config).to eq(max_jobs: 10, request_timeout: 30_000)
    end
  end

  describe ".streaming" do
    it "accepts empty kwargs" do
      worker = stub_const("StreamConfigWorker", Class.new(Busybee::Worker) do
        streaming
      end)

      expect(worker.configuration.streaming_config).to eq({})
    end

    it "stores kwargs for future use" do
      worker = stub_const("StreamKwargsWorker", Class.new(Busybee::Worker) do
        streaming buffer_size: 100
      end)

      expect(worker.configuration.streaming_config).to eq(buffer_size: 100)
    end
  end

  describe ".job_timeout" do
    it "sets job timeout" do
      worker = stub_const("TimeoutWorker", Class.new(Busybee::Worker) do
        job_timeout 300_000
      end)

      expect(worker.configuration.job_timeout).to eq(300_000)
    end
  end

  describe ".backoff" do
    it "sets backoff" do
      worker = stub_const("BackoffWorker", Class.new(Busybee::Worker) do
        backoff 30_000
      end)

      expect(worker.configuration.backoff).to eq(30_000)
    end
  end

  describe "load-time validation" do
    it "raises on input without source" do
      expect do
        stub_const("NoSourceWorker", Class.new(Busybee::Worker) do
          input :order_id, source: []
        end)
      end.to raise_error(Busybee::InvalidWorkerDefinition, /source:.*required.*:order_id/)
    end

    it "raises on input with invalid source" do
      expect do
        stub_const("BadSourceWorker", Class.new(Busybee::Worker) do
          input :order_id, source: :database
        end)
      end.to raise_error(Busybee::InvalidWorkerDefinition, /Invalid source.*:database.*:order_id/)
    end

    it "raises on input with blank name" do
      expect do
        stub_const("BlankNameWorker", Class.new(Busybee::Worker) do
          input :"", source: :variable
        end)
      end.to raise_error(Busybee::InvalidWorkerDefinition, /Name is required/)
    end

    it "raises on input with invalid type" do
      expect do
        stub_const("BadTypeWorker", Class.new(Busybee::Worker) do
          variable :order_id, type: :array
        end)
      end.to raise_error(Busybee::InvalidWorkerDefinition, /Invalid type.*:array.*:order_id/)
    end

    it "raises on output with invalid type" do
      expect do
        stub_const("BadOutputTypeWorker", Class.new(Busybee::Worker) do
          output :result, type: :hash
        end)
      end.to raise_error(Busybee::InvalidWorkerDefinition, /Invalid type.*:hash.*:result/)
    end

    it "raises when both required: and default: are explicitly passed" do
      expect do
        stub_const("ConflictWorker", Class.new(Busybee::Worker) do
          variable :channel, required: true, default: "email"
        end)
      end.to raise_error(Busybee::InvalidWorkerDefinition, /required:.*default:.*mutually exclusive.*:channel/)
    end

    it "raises when required: false and default: are both explicitly passed" do
      expect do
        stub_const("RedundantWorker", Class.new(Busybee::Worker) do
          variable :channel, required: false, default: "email"
        end)
      end.to raise_error(Busybee::InvalidWorkerDefinition, /required:.*default:.*mutually exclusive.*:channel/)
    end

    it "raises on duplicate input names" do
      expect do
        stub_const("DuplicateInputWorker", Class.new(Busybee::Worker) do
          variable :order_id
          variable :order_id
        end)
      end.to raise_error(Busybee::InvalidWorkerDefinition, /Input :order_id is already declared/)
    end

    it "raises on duplicate output names" do
      expect do
        stub_const("DuplicateOutputWorker", Class.new(Busybee::Worker) do
          output :result
          output :result
        end)
      end.to raise_error(Busybee::InvalidWorkerDefinition, /Output :result is already declared/)
    end

    it "raises when accessor name is a Ruby keyword" do
      expect do
        stub_const("KeywordWorker", Class.new(Busybee::Worker) do
          variable :return
        end)
      end.to raise_error(Busybee::InvalidWorkerDefinition, /Ruby keyword.*accessor_name:.*define_accessor: false/)
    end

    it "raises when accessor conflicts with an existing instance method" do
      expect do
        stub_const("ConflictMethodWorker", Class.new(Busybee::Worker) do
          def process; end

          variable :process
        end)
      end.to raise_error(Busybee::InvalidWorkerDefinition, /method :process already exists.*accessor_name:/)
    end

    it "does not conflict with class-level DSL methods like description" do
      expect do
        stub_const("DescInputWorker", Class.new(Busybee::Worker) do
          variable :description
        end)
      end.not_to raise_error
    end

    it "raises when define_accessor: false is combined with accessor_name:" do
      expect do
        stub_const("PointlessNameWorker", Class.new(Busybee::Worker) do
          variable :order_id, define_accessor: false, accessor_name: :oid
        end)
      end.to raise_error(Busybee::InvalidWorkerDefinition, /define_accessor: false.*accessor_name:.*mutually exclusive/)
    end

    it "raises on invalid runner mode" do
      expect do
        stub_const("BadModeWorker", Class.new(Busybee::Worker) do
          runner_mode :batch
        end)
      end.to raise_error(Busybee::InvalidWorkerDefinition, /Invalid runner mode/)
    end

    it "raises on unknown polling kwargs" do
      expect do
        stub_const("BadPollingWorker", Class.new(Busybee::Worker) do
          polling batch_size: 10
        end)
      end.to raise_error(Busybee::InvalidWorkerDefinition, /Unknown polling config.*:batch_size/)
    end

    it "raises on job_timeout with invalid type" do
      expect do
        stub_const("BadTimeoutWorker", Class.new(Busybee::Worker) do
          job_timeout "5 minutes"
        end)
      end.to raise_error(Busybee::InvalidWorkerDefinition, /job_timeout.*Integer.*ActiveSupport::Duration/)
    end

    it "raises on backoff with invalid type" do
      expect do
        stub_const("BadBackoffWorker", Class.new(Busybee::Worker) do
          backoff "30 seconds"
        end)
      end.to raise_error(Busybee::InvalidWorkerDefinition, /backoff.*Integer.*ActiveSupport::Duration/)
    end

    it "deduplicates sources silently" do
      worker = stub_const("DupSourceWorker", Class.new(Busybee::Worker) do
        input :order_id, source: %i[variable variable]
      end)

      expect(worker.configuration.inputs.first.source).to eq([:variable])
    end
  end

  describe ".configuration" do
    it "returns a Configuration instance" do
      worker = stub_const("ConfigWorker", Class.new(Busybee::Worker))
      expect(worker.configuration).to be_a(Busybee::Worker::Configuration)
    end

    it "is memoized per class" do
      worker = stub_const("MemoWorker", Class.new(Busybee::Worker))
      first_call = worker.configuration
      second_call = worker.configuration
      expect(first_call).to be(second_call)
    end

    it "is independent per subclass" do
      worker1 = stub_const("Worker1", Class.new(Busybee::Worker))
      worker2 = stub_const("Worker2", Class.new(Busybee::Worker))
      expect(worker1.configuration).not_to be(worker2.configuration)
    end
  end

  # Mission 9: autocomplete, autofail, unhealthy_on DSL methods will be tested here.
end
