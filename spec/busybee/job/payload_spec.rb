# frozen_string_literal: true

require "busybee/job/payload"

RSpec.describe Busybee::Job::Payload do
  subject(:payload) { described_class.new(raw_job) }

  it_behaves_like "a two-cardinality projection" do
    let(:projectable) { payload }
  end

  let(:raw_job) do
    # rubocop:disable RSpec/VerifiedDoubles
    double(
      "Busybee::GRPC::ActivatedJob",
      key: 12_345,
      type: "process_order",
      processInstanceKey: 67_890,
      bpmnProcessId: "order-flow",
      elementId: "Activity_HandleOrder",
      retries: 3,
      deadline: 1_640_000_000_000,
      variables: '{"order_id":"abc-123"}',
      customHeaders: '{"priority":"high"}'
    )
    # rubocop:enable RSpec/VerifiedDoubles
  end

  describe "protobuf accessors" do
    it "exposes scalar fields directly from the protobuf" do
      expect(payload.key).to eq(12_345)
      expect(payload.type).to eq("process_order")
      expect(payload.process_instance_key).to eq(67_890)
      expect(payload.bpmn_process_id).to eq("order-flow")
      expect(payload.element_id).to eq("Activity_HandleOrder")
      expect(payload.retries).to eq(3)
    end

    it "aliases #job_type to #type so hook filters can read it by its domain name" do
      expect(payload.job_type).to eq(payload.type)
    end

    it "computes a frozen UTC Time deadline from the millisecond protobuf field" do
      expect(payload.deadline).to be_a(Time)
      expect(payload.deadline).to be_utc
      expect(payload.deadline).to be_frozen
      expect(payload.deadline.to_i).to eq(1_640_000_000)
    end

    it "memoizes the deadline" do
      first = payload.deadline
      expect(payload.deadline).to be(first)
    end
  end

  describe "#variables" do
    it "parses the JSON-encoded variables field" do
      expect(payload.variables).to eq("order_id" => "abc-123")
    end

    it "memoizes the parsed result" do
      first = payload.variables
      expect(payload.variables).to be(first)
    end

    it "raises InvalidJobJson with attribute context on malformed JSON" do
      allow(raw_job).to receive(:variables).and_return("not json")

      expect { payload.variables }.
        to raise_error(Busybee::InvalidJobJson, /Failed to parse job variables/)
    end
  end

  describe "#headers" do
    it "parses the JSON-encoded customHeaders field" do
      expect(payload.headers).to eq("priority" => "high")
    end

    it "memoizes the parsed result" do
      first = payload.headers
      expect(payload.headers).to be(first)
    end

    it "raises InvalidJobJson with attribute context on malformed JSON" do
      allow(raw_job).to receive(:customHeaders).and_return("not json")

      expect { payload.headers }.
        to raise_error(Busybee::InvalidJobJson, /Failed to parse job headers/)
    end
  end

  describe "#context_tags" do
    it "projects the low-cardinality immutable payload fields" do
      expect(payload.context_tags).to eq(
        job_type: "process_order",
        bpmn_process_id: "order-flow",
        element_id: "Activity_HandleOrder"
      )
    end

    it "omits retries and deadline (Job overlays those override-aware values)" do
      expect(payload.context_tags).not_to have_key(:retries)
      expect(payload.context_tags).not_to have_key(:deadline)
    end
  end

  describe "#logging_context" do
    it "extends context_tags with the high-cardinality identifiers" do
      expect(payload.logging_context).to eq(
        job_type: "process_order",
        bpmn_process_id: "order-flow",
        element_id: "Activity_HandleOrder",
        job_key: 12_345,
        process_instance_key: 67_890
      )
    end

    it "omits deadline (Job overlays the override-aware value)" do
      expect(payload.logging_context).not_to have_key(:deadline)
    end
  end
end
