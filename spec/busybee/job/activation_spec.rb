# frozen_string_literal: true

require "busybee/job/activation"

RSpec.describe Busybee::Job::Activation do
  subject(:activation) { described_class.new }

  it_behaves_like "a two-cardinality projection" do
    let(:projectable) do
      described_class.new.tap { |a| a.harvest!({ source: :stream, buffered: true, worker_class: String }) }
    end
  end

  describe "initial state" do
    it "has no worker or source, and is not buffered" do
      expect(activation.worker).to be_nil
      expect(activation.source).to be_nil
      expect(activation.buffered?).to be(false)
    end

    it "derives a nil worker_class" do
      expect(activation.worker_class).to be_nil
    end
  end

  describe "#harvest!" do
    it "extracts and applies source and buffered" do
      kwargs = { source: :stream, buffered: true }
      activation.harvest!(kwargs)

      expect(activation.source).to eq(:stream)
      expect(activation.buffered?).to be(true)
      expect(kwargs).to be_empty
    end

    it "harvests buffered: false (received unbuffered)" do
      activation.harvest!(source: :poll, buffered: false)
      expect(activation.buffered?).to be(false)
    end

    it "leaves buffered? false when not in kwargs" do
      activation.harvest!(source: :stream)
      expect(activation.buffered?).to be(false)
    end

    it "captures worker later (second harvest call)" do
      worker_class = stub_const("MyWorker", Class.new)
      worker_instance = worker_class.allocate

      activation.harvest!(source: :poll)
      activation.harvest!(worker: worker_instance)

      expect(activation.worker).to be(worker_instance)
      expect(activation.worker_class).to eq(worker_class)
    end

    it "captures worker_status (the runner's point-in-time snapshot)" do
      status = Object.new
      activation.harvest!(worker_status: status)
      expect(activation.worker_status).to be(status)
    end

    it "overwrites worker_status on a later harvest (execution re-stamp wins)" do
      first = Object.new
      second = Object.new
      activation.harvest!(worker_status: first)
      activation.harvest!(worker_status: second)
      expect(activation.worker_status).to be(second)
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

    it "includes buffered once harvested (the low-card per-job bit)" do
      activation.harvest!(source: :stream, buffered: true)
      expect(activation.context_tags).to include(buffered: true)
    end

    it "excludes worker_status (a rich object, not a loggable tag)" do
      activation.harvest!(source: :poll, worker_status: Object.new)

      expect(activation.context_tags).not_to have_key(:worker_status)
      expect(activation.logging_context).not_to have_key(:worker_status)
    end
  end

  describe "#logging_context" do
    it "is empty before population" do
      expect(activation.logging_context).to eq({})
    end

    it "mirrors context_tags (depth is no longer on the job; it lives on Worker::Status)" do
      worker_class = stub_const("MyWorker", Class.new)
      activation.harvest!(source: :stream, buffered: true, worker: worker_class.allocate)

      expect(activation.logging_context).to eq(
        source: :stream, worker_class: "MyWorker", buffered: true
      )
    end
  end
end
