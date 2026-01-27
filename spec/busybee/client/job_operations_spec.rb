# frozen_string_literal: true

require "active_support/core_ext/numeric/time"

RSpec.describe Busybee::Client::JobOperations do
  let(:client) { Busybee::Client.new(insecure: true, cluster_address: "localhost:26500") }
  let(:stub) { instance_double(Busybee::GRPC::Gateway::Stub) }

  before { allow(client.credentials).to receive(:grpc_stub).and_return(stub) }

  describe "#complete_job" do
    let(:response) { double("CompleteJobResponse") } # rubocop:disable RSpec/VerifiedDoubles

    it "completes a job and returns truthy value" do
      allow(stub).to receive(:complete_job).and_return(response)

      result = client.complete_job(123456, vars: {})

      expect(result).to be_truthy
    end

    it "sends job key in request" do
      allow(stub).to receive(:complete_job).and_return(response)

      client.complete_job(123456, vars: {})

      expect(stub).to have_received(:complete_job).with(
        having_attributes(jobKey: 123456)
      )
    end

    it "defaults to empty variables hash" do
      allow(stub).to receive(:complete_job).and_return(response)

      client.complete_job(123456)

      expect(stub).to have_received(:complete_job).with(
        having_attributes(variables: "{}")
      )
    end

    it "serializes variables to JSON" do
      allow(stub).to receive(:complete_job).and_return(response)

      client.complete_job(123456, vars: { result: "success", orderId: 999 })

      expect(stub).to have_received(:complete_job).with(
        having_attributes(variables: '{"result":"success","orderId":999}')
      )
    end

    it "wraps GRPC errors" do
      grpc_error = GRPC::NotFound.new("job not found")
      allow(stub).to receive(:complete_job).and_raise(grpc_error)

      expect { client.complete_job(123456) }.to raise_error(Busybee::GRPC::Error)
    end
  end

  describe "#fail_job" do
    let(:response) { double("FailJobResponse") } # rubocop:disable RSpec/VerifiedDoubles

    it "fails a job and returns truthy value" do
      allow(stub).to receive(:fail_job).and_return(response)

      result = client.fail_job(123456, "Something went wrong")

      expect(result).to be_truthy
    end

    it "sends job key and error message in request" do
      allow(stub).to receive(:fail_job).and_return(response)

      client.fail_job(123456, "Something went wrong")

      expect(stub).to have_received(:fail_job).with(
        having_attributes(
          jobKey: 123456,
          errorMessage: "Something went wrong"
        )
      )
    end

    it "requires error_message parameter" do
      expect { client.fail_job(123456) }.to raise_error(ArgumentError)
    end

    it "supports optional retries parameter" do
      allow(stub).to receive(:fail_job).and_return(response)

      client.fail_job(123456, "Error", retries: 5)

      expect(stub).to have_received(:fail_job).with(
        having_attributes(retries: 5)
      )
    end

    it "supports optional backoff parameter as integer milliseconds" do
      allow(stub).to receive(:fail_job).and_return(response)

      client.fail_job(123456, "Error", backoff: 5000)

      expect(stub).to have_received(:fail_job).with(
        having_attributes(retryBackOff: 5000)
      )
    end

    it "supports optional backoff parameter as Duration object" do
      duration = 5.seconds
      allow(stub).to receive(:fail_job).and_return(response)

      client.fail_job(123456, "Error", backoff: duration)

      expect(stub).to have_received(:fail_job).with(
        having_attributes(retryBackOff: 5000)
      )
    end

    it "uses configured default_fail_job_backoff when backoff not provided" do
      Busybee.default_fail_job_backoff = 10_000
      allow(stub).to receive(:fail_job).and_return(response)

      client.fail_job(123456, "Error")

      expect(stub).to have_received(:fail_job).with(
        having_attributes(retryBackOff: 10_000)
      )
    ensure
      Busybee.default_fail_job_backoff = nil
    end

    it "falls back to Defaults::DEFAULT_FAIL_JOB_BACKOFF_MS when not configured" do
      Busybee.default_fail_job_backoff = nil
      allow(stub).to receive(:fail_job).and_return(response)

      client.fail_job(123456, "Error")

      expect(stub).to have_received(:fail_job).with(
        having_attributes(retryBackOff: Busybee::Defaults::DEFAULT_FAIL_JOB_BACKOFF_MS)
      )
    end

    it "wraps GRPC errors" do
      grpc_error = GRPC::NotFound.new("job not found")
      allow(stub).to receive(:fail_job).and_raise(grpc_error)

      expect { client.fail_job(123456, "Error") }.to raise_error(Busybee::GRPC::Error)
    end
  end

  describe "#throw_bpmn_error" do
    let(:response) { double("ThrowErrorResponse") } # rubocop:disable RSpec/VerifiedDoubles

    it "throws a BPMN error and returns truthy value" do
      allow(stub).to receive(:throw_error).and_return(response)

      result = client.throw_bpmn_error(123456, "ORDER_NOT_FOUND")

      expect(result).to be_truthy
    end

    it "sends job key and error code in request" do
      allow(stub).to receive(:throw_error).and_return(response)

      client.throw_bpmn_error(123456, "ORDER_NOT_FOUND")

      expect(stub).to have_received(:throw_error).with(
        having_attributes(
          jobKey: 123456,
          errorCode: "ORDER_NOT_FOUND"
        )
      )
    end

    it "requires error_code parameter" do
      expect { client.throw_bpmn_error(123456) }.to raise_error(ArgumentError)
    end

    it "defaults message to empty string" do
      allow(stub).to receive(:throw_error).and_return(response)

      client.throw_bpmn_error(123456, "ERROR_CODE")

      expect(stub).to have_received(:throw_error).with(
        having_attributes(errorMessage: "")
      )
    end

    it "supports optional message parameter" do
      allow(stub).to receive(:throw_error).and_return(response)

      client.throw_bpmn_error(
        123456,
        "ORDER_NOT_FOUND",
        message: "Order 550e8400 not found in database"
      )

      expect(stub).to have_received(:throw_error).with(
        having_attributes(
          errorCode: "ORDER_NOT_FOUND",
          errorMessage: "Order 550e8400 not found in database"
        )
      )
    end

    it "wraps GRPC errors" do
      grpc_error = GRPC::NotFound.new("job not found")
      allow(stub).to receive(:throw_error).and_raise(grpc_error)

      expect do
        client.throw_bpmn_error(123456, "ERROR_CODE")
      end.to raise_error(Busybee::GRPC::Error)
    end
  end

  describe "#update_job_retries" do
    let(:response) { double("UpdateJobRetriesResponse") } # rubocop:disable RSpec/VerifiedDoubles

    it "updates job retries and returns truthy value" do
      allow(stub).to receive(:update_job_retries).and_return(response)

      result = client.update_job_retries(123456, 5)

      expect(result).to be_truthy
    end

    it "sends job key and retries in request" do
      allow(stub).to receive(:update_job_retries).and_return(response)

      client.update_job_retries(123456, 5)

      expect(stub).to have_received(:update_job_retries).with(
        having_attributes(
          jobKey: 123456,
          retries: 5
        )
      )
    end

    it "converts job key from string to integer" do
      allow(stub).to receive(:update_job_retries).and_return(response)

      client.update_job_retries("123456", 5)

      expect(stub).to have_received(:update_job_retries).with(
        having_attributes(jobKey: 123456)
      )
    end

    it "requires retries parameter" do
      expect { client.update_job_retries(123456) }.to raise_error(ArgumentError)
    end

    it "wraps GRPC errors" do
      grpc_error = GRPC::NotFound.new("job not found")
      allow(stub).to receive(:update_job_retries).and_raise(grpc_error)

      expect { client.update_job_retries(123456, 5) }.to raise_error(Busybee::GRPC::Error)
    end
  end

  describe "#update_job_timeout" do
    let(:response) { double("UpdateJobTimeoutResponse") } # rubocop:disable RSpec/VerifiedDoubles

    it "updates job timeout and returns truthy value" do
      allow(stub).to receive(:update_job_timeout).and_return(response)

      result = client.update_job_timeout(123456, 30_000)

      expect(result).to be_truthy
    end

    it "sends job key and timeout in request" do
      allow(stub).to receive(:update_job_timeout).and_return(response)

      client.update_job_timeout(123456, 30_000)

      expect(stub).to have_received(:update_job_timeout).with(
        having_attributes(
          jobKey: 123456,
          timeout: 30_000
        )
      )
    end

    it "converts job key from string to integer" do
      allow(stub).to receive(:update_job_timeout).and_return(response)

      client.update_job_timeout("123456", 30_000)

      expect(stub).to have_received(:update_job_timeout).with(
        having_attributes(jobKey: 123456)
      )
    end

    it "requires timeout parameter" do
      expect { client.update_job_timeout(123456) }.to raise_error(ArgumentError)
    end

    it "supports timeout as Duration object" do
      allow(stub).to receive(:update_job_timeout).and_return(response)

      client.update_job_timeout(123456, 30.seconds)

      expect(stub).to have_received(:update_job_timeout).with(
        having_attributes(timeout: 30_000)
      )
    end

    it "wraps GRPC errors" do
      grpc_error = GRPC::NotFound.new("job not found")
      allow(stub).to receive(:update_job_timeout).and_raise(grpc_error)

      expect { client.update_job_timeout(123456, 30_000) }.to raise_error(Busybee::GRPC::Error)
    end
  end

  describe "#with_each_job" do
    # rubocop:disable RSpec/IndexedLet, Lint/EmptyBlock
    let(:raw_job1) do
      Busybee::GRPC::ActivatedJob.new(
        key: 111,
        type: "test-job",
        processInstanceKey: 789,
        bpmnProcessId: "test-process",
        variables: '{"foo":"bar"}',
        customHeaders: "{}",
        retries: 3,
        deadline: (Time.now.to_f * 1000).to_i
      )
    end
    let(:raw_job2) do
      Busybee::GRPC::ActivatedJob.new(
        key: 222,
        type: "test-job",
        processInstanceKey: 790,
        bpmnProcessId: "test-process",
        variables: '{"baz":"qux"}',
        customHeaders: "{}",
        retries: 3,
        deadline: (Time.now.to_f * 1000).to_i
      )
    end
    let(:raw_job3) do
      Busybee::GRPC::ActivatedJob.new(
        key: 333,
        type: "test-job",
        processInstanceKey: 791,
        bpmnProcessId: "test-process",
        variables: '{"hello":"world"}',
        customHeaders: "{}",
        retries: 3,
        deadline: (Time.now.to_f * 1000).to_i
      )
    end
    # Multiple responses, each containing multiple jobs
    let(:responses) do
      [
        Busybee::GRPC::ActivateJobsResponse.new(jobs: [raw_job1, raw_job2]),
        Busybee::GRPC::ActivateJobsResponse.new(jobs: [raw_job3])
      ]
    end

    it "activates jobs and yields each job to the block" do
      allow(stub).to receive(:activate_jobs).and_return(responses)

      yielded_jobs = []
      client.with_each_job("test-job") do |job|
        yielded_jobs << job
      end

      expect(yielded_jobs.length).to eq(3)
      expect(yielded_jobs).to all(be_a(Busybee::Job))
      expect(yielded_jobs.map(&:key)).to eq([111, 222, 333])
    end

    it "returns count of jobs processed" do
      allow(stub).to receive(:activate_jobs).and_return(responses)

      count = client.with_each_job("test-job") { |_job| }

      expect(count).to eq(3)
    end

    it "sends job type and worker name in request" do
      allow(stub).to receive(:activate_jobs).and_return(responses)

      client.with_each_job("test-job") { |_job| }

      expect(stub).to have_received(:activate_jobs).with(
        having_attributes(
          type: "test-job",
          worker: Busybee.worker_name
        )
      )
    end

    it "uses default max_jobs from Defaults" do
      allow(stub).to receive(:activate_jobs).and_return(responses)

      client.with_each_job("test-job") { |_job| }

      expect(stub).to have_received(:activate_jobs).with(
        having_attributes(maxJobsToActivate: Busybee::Defaults::DEFAULT_MAX_JOBS)
      )
    end

    it "accepts custom max_jobs parameter" do
      allow(stub).to receive(:activate_jobs).and_return(responses)

      client.with_each_job("test-job", max_jobs: 10) { |_job| }

      expect(stub).to have_received(:activate_jobs).with(
        having_attributes(maxJobsToActivate: 10)
      )
    end

    it "uses default job_timeout from Defaults" do
      allow(stub).to receive(:activate_jobs).and_return(responses)

      client.with_each_job("test-job") { |_job| }

      expect(stub).to have_received(:activate_jobs).with(
        having_attributes(timeout: Busybee::Defaults::DEFAULT_JOB_TIMEOUT_MS)
      )
    end

    it "accepts custom job_timeout parameter" do
      allow(stub).to receive(:activate_jobs).and_return(responses)

      client.with_each_job("test-job", job_timeout: 30_000) { |_job| }

      expect(stub).to have_received(:activate_jobs).with(
        having_attributes(timeout: 30_000)
      )
    end

    it "supports job_timeout as Duration object" do
      allow(stub).to receive(:activate_jobs).and_return(responses)

      client.with_each_job("test-job", job_timeout: 30.seconds) { |_job| }

      expect(stub).to have_received(:activate_jobs).with(
        having_attributes(timeout: 30_000)
      )
    end

    it "uses default request_timeout from Defaults" do
      allow(stub).to receive(:activate_jobs).and_return(responses)

      client.with_each_job("test-job") { |_job| }

      expect(stub).to have_received(:activate_jobs).with(
        having_attributes(requestTimeout: Busybee::Defaults::DEFAULT_JOB_REQUEST_TIMEOUT_MS)
      )
    end

    it "accepts custom request_timeout parameter" do
      allow(stub).to receive(:activate_jobs).and_return(responses)

      client.with_each_job("test-job", request_timeout: 120_000) { |_job| }

      expect(stub).to have_received(:activate_jobs).with(
        having_attributes(requestTimeout: 120_000)
      )
    end

    it "supports request_timeout as Duration object" do
      allow(stub).to receive(:activate_jobs).and_return(responses)

      client.with_each_job("test-job", request_timeout: 2.minutes) { |_job| }

      expect(stub).to have_received(:activate_jobs).with(
        having_attributes(requestTimeout: 120_000)
      )
    end

    it "requires a block" do
      expect do
        client.with_each_job("test-job")
      end.to raise_error(ArgumentError, /block required/)
    end

    it "wraps GRPC errors" do
      grpc_error = GRPC::Unavailable.new("service unavailable")
      allow(stub).to receive(:activate_jobs).and_raise(grpc_error)

      expect do
        client.with_each_job("test-job") { |_job| }
      end.to raise_error(Busybee::GRPC::Error)
    end
    # rubocop:enable RSpec/IndexedLet, Lint/EmptyBlock
  end

  describe "#open_job_stream" do
    let(:operation) { instance_double(GRPC::ActiveCall::Operation) }
    let(:enumerator) { instance_double(Enumerator) }

    before do
      allow(operation).to receive(:execute).and_return(enumerator)
    end

    it "returns a Busybee::JobStream instance" do
      allow(stub).to receive(:stream_activated_jobs).and_return(operation)

      stream = client.open_job_stream("test-job")

      expect(stream).to be_a(Busybee::JobStream)
    end

    it "passes return_op: true to stream_activated_jobs" do
      allow(stub).to receive(:stream_activated_jobs).and_return(operation)

      client.open_job_stream("test-job")

      expect(stub).to have_received(:stream_activated_jobs).with(anything, return_op: true)
    end

    it "sends job type in request" do
      allow(stub).to receive(:stream_activated_jobs).and_return(operation)

      client.open_job_stream("send-email")

      expect(stub).to have_received(:stream_activated_jobs).with(
        having_attributes(type: "send-email"),
        return_op: true
      )
    end

    it "sends worker name in request" do
      allow(stub).to receive(:stream_activated_jobs).and_return(operation)

      client.open_job_stream("test-job")

      expect(stub).to have_received(:stream_activated_jobs).with(
        having_attributes(worker: Busybee.worker_name),
        return_op: true
      )
    end

    it "uses default job_timeout from Defaults" do
      allow(stub).to receive(:stream_activated_jobs).and_return(operation)

      client.open_job_stream("test-job")

      expect(stub).to have_received(:stream_activated_jobs).with(
        having_attributes(timeout: Busybee::Defaults::DEFAULT_JOB_TIMEOUT_MS),
        return_op: true
      )
    end

    it "accepts custom job_timeout parameter" do
      allow(stub).to receive(:stream_activated_jobs).and_return(operation)

      client.open_job_stream("test-job", job_timeout: 30_000)

      expect(stub).to have_received(:stream_activated_jobs).with(
        having_attributes(timeout: 30_000),
        return_op: true
      )
    end

    it "supports job_timeout as Duration object" do
      allow(stub).to receive(:stream_activated_jobs).and_return(operation)

      client.open_job_stream("test-job", job_timeout: 30.seconds)

      expect(stub).to have_received(:stream_activated_jobs).with(
        having_attributes(timeout: 30_000),
        return_op: true
      )
    end

    it "wraps GRPC errors" do
      grpc_error = GRPC::InvalidArgument.new("type is blank")
      allow(stub).to receive(:stream_activated_jobs).and_raise(grpc_error)

      expect do
        client.open_job_stream("test-job")
      end.to raise_error(Busybee::GRPC::Error)
    end
  end
end
