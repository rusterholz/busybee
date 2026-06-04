# frozen_string_literal: true

require "busybee/job/activation"

RSpec.describe Busybee::Job::Activation do
  subject(:activation) { described_class.new }

  describe "initial state" do
    it "has no worker, source, or buffer_size" do
      expect(activation.worker).to be_nil
      expect(activation.source).to be_nil
      expect(activation.buffer_size).to be_nil
    end

    it "derives a nil worker_class" do
      expect(activation.worker_class).to be_nil
    end
  end

  describe "#harvest!" do
    it "extracts and applies source and buffer_size" do
      kwargs = { source: :stream, buffer_size: 3 }
      activation.harvest!(kwargs)

      expect(activation.source).to eq(:stream)
      expect(activation.buffer_size).to eq(3)
      expect(kwargs).to be_empty
    end

    it "preserves buffer_size of 0 (queue empty but buffered)" do
      activation.harvest!(buffer_size: 0)
      expect(activation.buffer_size).to eq(0)
    end

    it "leaves buffer_size nil when not in kwargs" do
      activation.harvest!(source: :stream)
      expect(activation.buffer_size).to be_nil
    end

    it "captures worker later (second harvest call)" do
      worker_class = stub_const("MyWorker", Class.new)
      worker_instance = worker_class.allocate

      activation.harvest!(source: :poll)
      activation.harvest!(worker: worker_instance)

      expect(activation.worker).to be(worker_instance)
      expect(activation.worker_class).to eq(worker_class)
    end

    it "leaves unknown keys in the kwargs hash (for downstream harvesters)" do
      kwargs = { source: :poll, my_scratch: "value" }
      activation.harvest!(kwargs)

      expect(activation.source).to eq(:poll)
      expect(kwargs).to eq(my_scratch: "value")
    end

    it "is a no-op when no Activation keys are present" do
      kwargs = { my_scratch: "value" }
      activation.harvest!(kwargs)

      expect(activation.source).to be_nil
      expect(kwargs).to eq(my_scratch: "value")
    end

    it "accepts :poll and :stream as valid sources" do
      activation.harvest!(source: :poll)
      expect(activation.source).to eq(:poll)

      activation = described_class.new
      activation.harvest!(source: :stream)
      expect(activation.source).to eq(:stream)
    end

    it "raises on unknown source values" do
      expect { activation.harvest!(source: :unknown) }.
        to raise_error(ArgumentError, /Invalid source/)
    end
  end

  describe "#context_tags" do
    it "is empty before population" do
      expect(activation.context_tags).to eq({})
    end

    it "exposes source and worker_class name (low-card)" do
      worker_class = stub_const("MyWorker", Class.new)
      activation.harvest!(source: :poll, worker: worker_class.allocate)

      expect(activation.context_tags).to eq(source: :poll, worker_class: "MyWorker")
    end
  end

  describe "#logging_context" do
    it "is empty before population" do
      expect(activation.logging_context).to eq({})
    end

    it "extends context_tags with buffer_size" do
      worker_class = stub_const("MyWorker", Class.new)
      activation.harvest!(source: :stream, buffer_size: 5, worker: worker_class.allocate)

      expect(activation.logging_context).to eq(
        source: :stream, worker_class: "MyWorker", buffer_size: 5
      )
    end

    it "includes buffer_size of 0" do
      activation.harvest!(source: :stream, buffer_size: 0)
      expect(activation.logging_context[:buffer_size]).to eq(0)
    end
  end
end
