# frozen_string_literal: true

RSpec.describe Busybee::Worker do
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
      variables: '{"order_id":"abc-123"}',
      customHeaders: '{"priority":"high"}'
    )
    # rubocop:enable RSpec/VerifiedDoubles
  end

  let(:job) { Busybee::Job.new(raw_job, client: client) }

  let(:minimal_worker) do
    stub_const("MinimalWorker", Class.new(described_class))
  end

  let(:performing_worker) do
    stub_const("PerformingWorker", Class.new(described_class) do
      define_method(:perform) do
        { processed: true }
      end
    end)
  end

  describe ".perform_job" do
    # Mission 7: bare-bones — instantiate, call perform, return result.
    # Mission 9: will add input validation, autocomplete, autofail, unhealthy_on wrapping.

    it "calls perform on a new instance and returns the result" do
      result = performing_worker.perform_job(job)
      expect(result).to eq(processed: true)
    end

    it "raises NotImplementedError when perform is not overridden" do
      expect { minimal_worker.perform_job(job) }.to raise_error(NotImplementedError, /perform/)
    end
  end

  describe "#perform" do
    it "raises NotImplementedError by default" do
      instance = minimal_worker.new(job)
      expect { instance.perform }.to raise_error(NotImplementedError, /perform/)
    end

    it "can be overridden in subclasses" do
      instance = performing_worker.new(job)
      expect(instance.perform).to eq(processed: true)
    end
  end

  describe "#job" do
    it "exposes the job passed to the constructor" do
      instance = minimal_worker.new(job)
      expect(instance.job).to be(job)
    end
  end

  describe "delegations to job" do
    let(:instance) { performing_worker.new(job) }

    describe "#variables" do
      it "delegates to job" do
        expect(instance.variables).to eq(job.variables)
      end
    end

    describe "#headers" do
      it "delegates to job" do
        expect(instance.headers).to eq(job.headers)
      end
    end

    describe "#complete!" do
      it "delegates to job" do
        allow(client).to receive(:complete_job)
        instance.complete!(result: "done")
        expect(client).to have_received(:complete_job).with(123456, vars: { result: "done" })
      end
    end

    describe "#fail!" do
      it "delegates to job" do
        allow(client).to receive(:fail_job)
        instance.fail!("Something broke", retries: 2)
        expect(client).to have_received(:fail_job).with(123456, "Something broke", retries: 2, backoff: nil)
      end
    end

    describe "#throw_bpmn_error!" do
      it "delegates to job" do
        allow(client).to receive(:throw_bpmn_error)
        instance.throw_bpmn_error!(:order_not_found, "Order missing")
        expect(client).to have_received(:throw_bpmn_error).with(123456, "ORDER_NOT_FOUND", message: "Order missing")
      end
    end

    describe "#update_retries" do
      it "delegates to job" do
        allow(client).to receive(:update_job_retries)
        instance.update_retries(5)
        expect(client).to have_received(:update_job_retries).with(123456, 5)
      end
    end

    describe "#update_timeout" do
      it "delegates to job" do
        allow(client).to receive(:update_job_timeout)
        instance.update_timeout(30_000)
        expect(client).to have_received(:update_job_timeout).with(123456, 30_000)
      end
    end
  end
end
