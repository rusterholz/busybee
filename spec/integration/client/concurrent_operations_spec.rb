# frozen_string_literal: true

require "active_support/core_ext/numeric/time"

# Tests that a single Busybee::Client (and its underlying GRPC stub) can handle
# multiple concurrent operations via HTTP/2 multiplexing:
# - Multiple job streams consuming different job types simultaneously
# - Unary operations (deploy, start, complete, publish_message) while streams are active
#
# This verifies thread safety and proper HTTP/2 connection sharing.
RSpec.describe Busybee::Client, "concurrent operations" do # rubocop:disable RSpec/DescribeMethod
  let(:multi_job_bpmn_path) { File.expand_path("../../fixtures/multi_job_process.bpmn", __dir__) }

  shared_examples "concurrent operations" do
    # rubocop:disable RSpec/MultipleExpectations, RSpec/ExampleLength
    it "handles multiple streams and unary operations concurrently on a single client" do
      # Deploy a process with multiple job types
      deploy_result = client.deploy_process(multi_job_bpmn_path)
      expect(deploy_result).to include("multi-job-process")

      # Track jobs received by each stream
      stream1_jobs = []
      stream2_jobs = []
      instance_keys = []

      # Open TWO streams on the SAME client for different job types
      stream1 = client.open_job_stream("job-type-a", job_timeout: 30.seconds)
      stream2 = client.open_job_stream("job-type-b", job_timeout: 30.seconds)

      # Consume streams in background threads
      consumer1 = Thread.new do
        stream1.each do |job|
          stream1_jobs << job
          # Don't complete yet - we'll do that via client.complete_job to test concurrency
          break if stream1_jobs.length >= 2
        end
      end

      consumer2 = Thread.new do
        stream2.each do |job|
          stream2_jobs << job
          job.complete! # Complete inline to show both patterns work
          break if stream2_jobs.length >= 2
        end
      end

      # Give streams time to register with gateway
      sleep 0.3

      # Now perform multiple unary operations while BOTH streams are active:

      # 1. Start multiple process instances (creates jobs for both streams)
      2.times do
        key = client.start_instance("multi-job-process")
        expect(key).to be_a(Integer)
        instance_keys << key
      end

      # 2. Publish a message while streams are active (tests message operations)
      # Using a correlation key that won't match anything - just verifying the call succeeds
      client.publish_message("test-concurrent-message", correlation_key: "no-match-#{SecureRandom.hex(4)}")

      # 3. Wait for stream1 to receive jobs, then complete them via client.complete_job
      #    This tests unary complete_job while streams are still active
      deadline = Time.now + 10
      sleep 0.1 while stream1_jobs.length < 2 && Time.now < deadline

      stream1_jobs.each do |job|
        client.complete_job(job.key)
      end

      # 4. Wait for stream2 to finish (it completes jobs inline)
      consumer2.join(10)

      # 5. Verify both streams received their jobs
      expect(stream1_jobs.length).to eq(2)
      expect(stream1_jobs.map(&:type)).to all(eq("job-type-a"))

      expect(stream2_jobs.length).to eq(2)
      expect(stream2_jobs.map(&:type)).to all(eq("job-type-b"))

      # 6. Deploy a uniquified process while streams are still technically open
      #    Using uniquify: true ensures this is a NEW deployment, not a cache hit
      unique_deploy = deploy_process(multi_job_bpmn_path, uniquify: true)
      expect(unique_deploy[:process_id]).to start_with("test-process-")
      expect(unique_deploy[:process].processDefinitionKey).to be > 0
    ensure
      stream1&.close
      stream2&.close
      consumer1&.join(2)
      consumer2&.join(2)
      consumer1&.kill if consumer1&.alive?
      consumer2&.kill if consumer2&.alive?

      # Clean up any running instances
      instance_keys&.each do |key|
        request = Busybee::GRPC::CancelProcessInstanceRequest.new(processInstanceKey: key)
        grpc_client.cancel_process_instance(request)
      rescue GRPC::NotFound
        # Already completed
      end
    end
    # rubocop:enable RSpec/MultipleExpectations, RSpec/ExampleLength
  end

  context "with local Zeebe", :integration do
    around do |example|
      original = Busybee.credential_type
      Busybee.credential_type = :insecure
      example.run
      Busybee.credential_type = original
    end

    let(:client) { local_busybee_client }

    it_behaves_like "concurrent operations"
  end

  context "with Camunda Cloud", :camunda_cloud do
    around do |example|
      original = Busybee.credential_type
      Busybee.credential_type = :camunda_cloud
      example.run
      Busybee.credential_type = original
    end

    let(:client) { camunda_cloud_busybee_client }

    it_behaves_like "concurrent operations"
  end
end
