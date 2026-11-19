# frozen_string_literal: true

# Business IDs arrived across Camunda 8.9 and 8.10, and an older gateway drops
# the field without an error. Each example pins what 8.10 does and how an older
# gateway answers, so every row of the version matrix asserts.
RSpec.describe "Business IDs" do
  let(:fixtures) { %w[business_id_process business_id_message_process business_id_message_start_process] }
  let(:business_id) { "order-#{SecureRandom.hex(6)}" }
  let(:started) { [] }

  shared_examples "business IDs" do
    around { |example| isolate_busybee_hooks { example.run } }

    before { client.deploy_process(*fixtures.map { |name| File.expand_path("../../fixtures/#{name}.bpmn", __dir__) }) }

    after { started.each { |key| client.cancel_instance(key, ignore_missing: true) } }

    def start(process = "business-id-process", **kwargs)
      client.start_instance(process, **kwargs).tap { |key| started << key }
    end

    # The raw business ID on the instance's next job of this type; "" when the
    # gateway sent none.
    def raw_business_id_of(type, key)
      job = activate_job(type)
      expect(job.process_instance_key).to eq(key)
      job.raw.businessId
    end

    describe "#start_instance" do
      it "starts the instance with the business ID on 8.9 and later, and drops it before" do
        echoed = nil
        Busybee.after_call(rpc: :create_process_instance) { |call| echoed = call.result }

        key = start(business_id: business_id)

        expect(echoed.has_businessId?).to eq(gateway_at_least?("8.9"))
        expect(echoed.businessId).to eq(business_id) if gateway_at_least?("8.9")
        # 8.9 keeps the ID but doesn't send it on jobs
        expect(raw_business_id_of("business-id-task", key)).to eq(gateway_at_least?("8.10") ? business_id : "")
      end

      it "treats an empty business ID as none" do
        key = start(business_id: "")

        expect(raw_business_id_of("business-id-task", key)).to eq("")
      end
    end

    describe "#publish_message" do
      let(:correlation_key) { "corr-#{SecureRandom.hex(6)}" }

      def publish(**kwargs)
        client.publish_message("business-id-message", correlation_key: correlation_key, ttl: 30_000, **kwargs)
      end

      def correlated?(key)
        activate_job("business-id-message-task", timeout: 2_000).process_instance_key == key
      rescue Busybee::Testing::NoJobsAvailable
        false
      end

      it "correlates only to the instance with that business ID on 8.10, and to any instance before" do
        key = start("business-id-message-process", vars: { correlationId: correlation_key },
                                                   business_id: business_id)

        publish(business_id: "#{business_id}-other")
        expect(correlated?(key)).to eq(!gateway_at_least?("8.10"))
        next unless gateway_at_least?("8.10")

        publish(business_id: business_id)
        expect(correlated?(key)).to be(true)
      end

      it "correlates a message without a business ID to an instance that has one" do
        key = start("business-id-message-process", vars: { correlationId: correlation_key },
                                                   business_id: business_id)

        publish
        expect(correlated?(key)).to be(true)
      end

      it "gives the business ID to the instance a message start event creates on 8.10, and drops it before" do
        client.publish_message("business-id-start-message", correlation_key: "", ttl: 0, business_id: business_id)

        job = activate_job("business-id-message-start-task")
        started << job.process_instance_key
        expect(job.raw.businessId).to eq(gateway_at_least?("8.10") ? business_id : "")
      end
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

    it_behaves_like "business IDs"
  end

  context "with Camunda Cloud", :camunda_cloud do
    around do |example|
      original = Busybee.credential_type
      Busybee.credential_type = :camunda_cloud
      example.run
      Busybee.credential_type = original
    end

    let(:client) { camunda_cloud_busybee_client }

    it_behaves_like "business IDs"
  end
end
