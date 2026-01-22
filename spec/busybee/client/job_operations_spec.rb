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
end
