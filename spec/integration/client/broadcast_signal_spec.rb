# frozen_string_literal: true

RSpec.describe Busybee::Client, "#broadcast_signal" do
  shared_context "with deployed signal start process" do
    let(:bpmn_path) { File.expand_path("../../fixtures/signal_start_process.bpmn", __dir__) }
    let(:process_id) { deploy_process(bpmn_path)[:process_id] }

    # Clean up any leftover jobs before each test
    before do
      loop { activate_job("process-order", timeout: 100).mark_completed }
    rescue Busybee::Testing::NoJobAvailable
      # All jobs cleaned up
    end
  end

  shared_examples "broadcast_signal" do
    include_context "with deployed signal start process"

    it "broadcasts a signal that triggers a signal start event" do
      # Ensure the process is deployed
      expect(process_id).to be_a(String)

      # Broadcast the signal - this should create a new process instance
      signal_key = client.broadcast_signal("order-ready")

      # Verify the signal was broadcast
      expect(signal_key).to be_a(Integer)
      expect(signal_key).to be > 0

      # Verify a process instance was created by activating and completing the job
      activate_job("process-order").and_complete
    end

    it "broadcasts a signal with variables that are merged into the new instance" do
      # Broadcast signal with variables
      signal_key = client.broadcast_signal("order-ready",
                                           vars: { orderId: "123", customerEmail: "test@example.com" })

      expect(signal_key).to be > 0

      # Verify the new instance received the variables
      activate_job("process-order").
        expect_variables(orderId: "123", customerEmail: "test@example.com").
        and_complete
    end

    it "broadcasts a signal with empty variables hash" do
      signal_key = client.broadcast_signal("order-ready", vars: {})

      expect(signal_key).to be > 0

      # Verify instance was created
      activate_job("process-order").and_complete
    end

    it "broadcasts a signal that triggers multiple process instances" do
      # Broadcast the same signal twice - should create two instances
      signal_key_1 = client.broadcast_signal("order-ready", vars: { orderId: "111" })
      signal_key_2 = client.broadcast_signal("order-ready", vars: { orderId: "222" })

      expect(signal_key_1).to be > 0
      expect(signal_key_2).to be > 0
      expect(signal_key_1).not_to eq(signal_key_2)

      # Give Zeebe a moment to create instances and reach the service task
      sleep 0.1

      # Both instances should be waiting at the job - request more to verify only 2 exist
      jobs = activate_jobs("process-order", max_jobs: 5)

      # Convert enumerator to array
      jobs_array = jobs.to_a
      expect(jobs_array.size).to eq(2)

      # Verify each has the correct orderId
      order_ids = jobs_array.map { |j| j.variables["orderId"] }.sort
      expect(order_ids).to eq(%w[111 222])

      # Complete both jobs
      jobs_array.each(&:mark_completed)
    end

    it "handles broadcasting a signal that has no matching subscriptions" do
      # Broadcast a signal name that doesn't match any process definition
      # This should NOT raise an error - signals are broadcast regardless
      signal_key = client.broadcast_signal("non-existent-signal")

      expect(signal_key).to be_a(Integer)
      expect(signal_key).to be > 0

      # We can't verify that NO instances were created globally, but we can verify
      # that no instances of our fixture process were created (no jobs available)
      expect { activate_job("process-order") }.not_to have_available_jobs
    end

    it "handles broadcasting a signal with variables when there are no matching subscriptions" do
      # Broadcast a non-matching signal with variables
      signal_key = client.broadcast_signal("non-existent-signal",
                                           vars: { foo: "bar", count: 42 })

      expect(signal_key).to be_a(Integer)
      expect(signal_key).to be > 0

      # Verify no instances of our fixture process were created
      expect { activate_job("process-order") }.not_to have_available_jobs
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

    it_behaves_like "broadcast_signal"
  end

  context "with Camunda Cloud", :camunda_cloud do
    around do |example|
      original = Busybee.credential_type
      Busybee.credential_type = :camunda_cloud
      example.run
      Busybee.credential_type = original
    end

    let(:client) { camunda_cloud_busybee_client }

    it_behaves_like "broadcast_signal"
  end
end
