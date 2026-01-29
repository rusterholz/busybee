# frozen_string_literal: true

require "active_support/core_ext/numeric/time"

RSpec.describe Busybee::Client, "#open_job_stream" do
  let(:job_bpmn_path) { File.expand_path("../../fixtures/job_process.bpmn", __dir__) }

  shared_examples "open_job_stream" do
    around do |example|
      # Deploy the job process
      client.deploy_process(job_bpmn_path)

      if example.metadata[:skip_process_instance]
        example.run
      else
        with_process_instance("job-process") do
          example.run
        end
      end
    end

    it "returns a JobStream instance", :skip_process_instance do
      stream = client.open_job_stream("process-order")

      expect(stream).to be_a(Busybee::JobStream)
    ensure
      stream&.close
    end

    it "streams jobs as they become available", :skip_process_instance do
      stream = client.open_job_stream("process-order", job_timeout: 30.seconds)
      received_jobs = []

      # Start a thread to consume the stream
      consumer = Thread.new do
        stream.each do |job| # rubocop:disable Lint/UnreachableLoop
          received_jobs << job
          job.complete!
          break # Exit after first job for test purposes
        end
      end

      # Give the stream time to register with the gateway
      sleep 0.2

      # NOW create the process instance - the job should be pushed to the stream
      request = Busybee::GRPC::CreateProcessInstanceRequest.new(
        bpmnProcessId: "job-process",
        version: -1,
        variables: "{}"
      )
      response = grpc_client.create_process_instance(request)
      instance_key = response.processInstanceKey

      # Wait for the consumer to receive the job
      consumer.join(5) # 5 second timeout

      expect(received_jobs.length).to eq(1)
      expect(received_jobs.first).to be_a(Busybee::Job)
      expect(received_jobs.first.type).to eq("process-order")
    ensure
      stream&.close
      consumer&.kill if consumer&.alive?
      # Clean up the instance if still running
      begin
        request = Busybee::GRPC::CancelProcessInstanceRequest.new(processInstanceKey: instance_key)
        grpc_client.cancel_process_instance(request)
      rescue GRPC::NotFound
        # Already completed, ignore
      end
    end

    # CRITICAL: This test verifies that StreamActivatedJobs does NOT deliver pre-existing jobs.
    # Jobs created before the stream is opened are not pushed to the stream, but CAN be
    # retrieved via with_each_job (ActivateJobs RPC). This behavioral difference is important
    # for worker design - see project documentation.
    it "does NOT receive pre-existing jobs (but with_each_job does)" do
      # The around block already created a process instance with a job BEFORE this test runs
      # (via with_process_instance). That job exists but the stream hasn't been opened yet.

      stream = client.open_job_stream("process-order", job_timeout: 30.seconds)
      streamed_jobs = []

      # Start consuming the stream in a thread
      consumer = Thread.new do
        stream.each do |job|
          streamed_jobs << job
          job.complete!
        end
      end

      # Give the stream plenty of time to receive any jobs
      sleep 1.0

      # The stream should NOT have received the pre-existing job
      expect(streamed_jobs).to be_empty

      # But with_each_job SHOULD be able to get the pre-existing job
      polled_jobs = []
      client.with_each_job("process-order", request_timeout: 2.seconds) do |job|
        polled_jobs << job
        job.complete!
      end

      expect(polled_jobs.length).to eq(1)
      expect(polled_jobs.first.type).to eq("process-order")

      # Stream still should have received nothing (the job was consumed by with_each_job)
      expect(streamed_jobs).to be_empty
    ensure
      stream&.close
      consumer&.kill if consumer&.alive?
    end

    it "allows closing the stream from another thread", :skip_process_instance do
      stream = client.open_job_stream("non-existent-job-type", job_timeout: 30.seconds)
      iteration_started = false
      iteration_ended = false

      consumer = Thread.new do
        iteration_started = true
        stream.each { |_job| } # This would block forever without close
        iteration_ended = true
      end

      # Give the stream time to start iterating
      sleep 0.1 until iteration_started
      sleep 0.1 # Additional small delay

      # Close from main thread
      stream.close

      # Consumer should exit gracefully
      consumer.join(2)

      expect(stream).to be_closed
      expect(iteration_ended).to be(true)
      expect(consumer).not_to be_alive
    ensure
      stream&.close
      consumer&.kill if consumer&.alive?
    end

    it "supports custom job_timeout", :skip_process_instance do
      stream = client.open_job_stream("process-order", job_timeout: 10.seconds)

      expect(stream).to be_a(Busybee::JobStream)
    ensure
      stream&.close
    end

    it "raises StreamAlreadyClosed when iterating after close", :skip_process_instance do
      stream = client.open_job_stream("process-order")
      stream.close

      expect { stream.each { |_job| } }.to raise_error(Busybee::StreamAlreadyClosed) # rubocop:disable Lint/EmptyBlock
    end

    it "streams jobs from multiple process instances", :skip_process_instance do
      stream = client.open_job_stream("process-order", job_timeout: 30.seconds)
      received_jobs = []
      target_count = 3

      # Start a thread to consume the stream
      consumer = Thread.new do
        stream.each do |job|
          received_jobs << job
          job.complete!
          break if received_jobs.length >= target_count
        end
      end

      # Give the stream time to register
      sleep 0.2

      # Create multiple process instances
      instance_keys = []
      target_count.times do
        request = Busybee::GRPC::CreateProcessInstanceRequest.new(
          bpmnProcessId: "job-process",
          version: -1,
          variables: "{}"
        )
        response = grpc_client.create_process_instance(request)
        instance_keys << response.processInstanceKey
      end

      begin
        # Wait for the consumer to receive all jobs
        consumer.join(10) # 10 second timeout

        expect(received_jobs.length).to eq(target_count)
        expect(received_jobs.map(&:key).uniq.length).to eq(target_count) # All unique job keys
      ensure
        # Clean up all instances
        instance_keys.each do |key|
          request = Busybee::GRPC::CancelProcessInstanceRequest.new(processInstanceKey: key)
          grpc_client.cancel_process_instance(request)
        rescue GRPC::NotFound
          # Already completed, ignore
        end
      end
    ensure
      stream&.close
      consumer&.kill if consumer&.alive?
    end
  end

  context "with local Zeebe", :integration do
    around do |example|
      original = Busybee.credential_type
      Busybee.credential_type = :insecure
      example.run
      Busybee.credential_type = original
    end

    let(:client) { local_busybee_client }

    it_behaves_like "open_job_stream"
  end

  context "with Camunda Cloud", :camunda_cloud do
    around do |example|
      original = Busybee.credential_type
      Busybee.credential_type = :camunda_cloud
      example.run
      Busybee.credential_type = original
    end

    let(:client) { camunda_cloud_busybee_client }

    it_behaves_like "open_job_stream"
  end
end
