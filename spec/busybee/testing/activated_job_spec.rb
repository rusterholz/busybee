# frozen_string_literal: true

require "busybee/testing/activated_job"
require "json"

RSpec.describe Busybee::Testing::ActivatedJob do
  subject(:job) { described_class.new(raw_job, client: client) }

  let(:raw_job) do
    # Using plain double since protobuf generates accessors dynamically.
    # Field names verified against proto/gateway.proto ActivatedJob message.
    # rubocop:disable RSpec/VerifiedDoubles
    double(
      "Busybee::GRPC::ActivatedJob",
      key: 12_345,
      type: "process-order",
      processInstanceKey: 67_890,
      bpmnProcessId: "order-workflow",
      variables: '{"foo": "bar", "count": 42}',
      customHeaders: '{"task_type": "process_order"}',
      retries: 3,
      deadline: 1640000000000
    )
    # rubocop:enable RSpec/VerifiedDoubles
  end
  let(:client) { instance_double(Busybee::GRPC::Gateway::Stub) }

  describe "#key" do
    it "returns the job key" do
      expect(job.key).to eq(12_345)
    end
  end

  describe "#type" do
    it "returns the job type" do
      expect(job.type).to eq("process-order")
    end
  end

  describe "#process_instance_key" do
    it "returns the process instance key" do
      expect(job.process_instance_key).to eq(67_890)
    end
  end

  describe "#bpmn_process_id" do
    it "returns the BPMN process ID" do
      expect(job.bpmn_process_id).to eq("order-workflow")
    end
  end

  describe "#retries" do
    it "returns the retry count" do
      expect(job.retries).to eq(3)
    end
  end

  describe "#deadline" do
    it "returns the deadline timestamp" do
      expect(job.deadline).to eq(1640000000000)
    end
  end

  describe "#variables" do
    it "parses and returns variables as a hash with string keys" do
      expect(job.variables).to eq("foo" => "bar", "count" => 42)
    end

    it "memoizes the result" do
      expect(JSON).to receive(:parse).once.and_call_original # rubocop:disable RSpec/MessageSpies
      job.variables
      job.variables # second call should not parse again
    end
  end

  describe "#headers" do
    it "parses and returns custom headers as a hash with string keys" do
      expect(job.headers).to eq("task_type" => "process_order")
    end

    it "memoizes the result" do
      expect(JSON).to receive(:parse).once.and_call_original # rubocop:disable RSpec/MessageSpies
      job.headers
      job.headers # second call should not parse again
    end
  end

  describe "#expect_variables" do
    it "passes when variables include expected values" do
      expect { job.expect_variables("foo" => "bar") }.not_to raise_error
    end

    it "fails when variables do not include expected values" do
      expect { job.expect_variables("foo" => "wrong") }.to raise_error(RSpec::Expectations::ExpectationNotMetError)
    end

    it "returns self for chaining" do
      expect(job.expect_variables("foo" => "bar")).to be(job)
    end
  end

  describe "#expect_headers" do
    it "passes when headers include expected values" do
      expect { job.expect_headers("task_type" => "process_order") }.not_to raise_error
    end

    it "fails when headers do not include expected values" do
      expect { job.expect_headers("task_type" => "wrong") }.to raise_error(RSpec::Expectations::ExpectationNotMetError)
    end

    it "returns self for chaining" do
      expect(job.expect_headers("task_type" => "process_order")).to be(job)
    end
  end

  describe "#mark_completed" do
    it "sends CompleteJobRequest to client" do
      expect(client).to receive(:complete_job).with( # rubocop:disable RSpec/MessageSpies
        an_instance_of(Busybee::GRPC::CompleteJobRequest)
      )
      job.mark_completed
    end

    it "includes variables when provided" do
      expect(client).to receive(:complete_job) do |request| # rubocop:disable RSpec/MessageSpies
        expect(JSON.parse(request.variables)).to eq("result" => "success")
      end
      job.mark_completed(result: "success")
    end

    it "returns self" do
      allow(client).to receive(:complete_job)
      expect(job.mark_completed).to be(job)
    end
  end

  describe "#and_complete" do
    it "is an alias for mark_completed" do
      expect(client).to receive(:complete_job) # rubocop:disable RSpec/MessageSpies
      job.and_complete
    end
  end

  describe "#mark_failed" do
    it "sends FailJobRequest to client" do
      expect(client).to receive(:fail_job).with( # rubocop:disable RSpec/MessageSpies
        an_instance_of(Busybee::GRPC::FailJobRequest)
      )
      job.mark_failed
    end

    it "includes message and retries when provided" do
      expect(client).to receive(:fail_job) do |request| # rubocop:disable RSpec/MessageSpies
        expect(request.errorMessage).to eq("Something went wrong")
        expect(request.retries).to eq(2)
      end
      job.mark_failed("Something went wrong", retries: 2)
    end
  end

  describe "#and_fail" do
    it "is an alias for mark_failed" do
      expect(client).to receive(:fail_job) # rubocop:disable RSpec/MessageSpies
      job.and_fail
    end
  end

  describe "#throw_error_event" do
    it "sends ThrowErrorRequest to client" do
      expect(client).to receive(:throw_error).with( # rubocop:disable RSpec/MessageSpies
        an_instance_of(Busybee::GRPC::ThrowErrorRequest)
      )
      job.throw_error_event("ERROR_CODE")
    end

    it "includes code and message" do
      expect(client).to receive(:throw_error) do |request| # rubocop:disable RSpec/MessageSpies
        expect(request.errorCode).to eq("VALIDATION_FAILED")
        expect(request.errorMessage).to eq("Invalid input")
      end
      job.throw_error_event("VALIDATION_FAILED", "Invalid input")
    end
  end

  describe "#and_throw_error_event" do
    it "is an alias for throw_error_event" do
      expect(client).to receive(:throw_error) # rubocop:disable RSpec/MessageSpies
      job.and_throw_error_event("CODE")
    end
  end

  describe "#update_retries" do
    it "sends UpdateJobRetriesRequest to client" do
      expect(client).to receive(:update_job_retries).with( # rubocop:disable RSpec/MessageSpies
        an_instance_of(Busybee::GRPC::UpdateJobRetriesRequest)
      )
      job.update_retries(5)
    end
  end
end
