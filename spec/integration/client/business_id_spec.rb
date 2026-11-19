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
    # gateway sent none. 8.9 never sends it, so its "dropped" branches can't tell.
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

    describe "#assign_business_id" do
      it "assigns a running instance its business ID once on 8.10, and is unimplemented before" do
        key = start
        unless gateway_at_least?("8.10")
          expect { client.assign_business_id(key, business_id) }.to raise_error(Busybee::GRPC::Error) do |error|
            expect(error.grpc_status).to eq(:unimplemented)
          end
          next
        end

        expect(client.assign_process_instance_business_id(key, business_id)).to be_truthy
        expect { client.assign_business_id(key, business_id) }.to raise_error(Busybee::GRPC::Error) do |error|
          expect(error.grpc_status).to eq(:failed_precondition)
        end
      end

      it "hands the business ID only to jobs created after the assignment, on 8.10" do
        key = start
        assigned = gateway_at_least?("8.10") && client.assign_business_id(key, business_id)

        first = activate_job("business-id-task")
        expect([first.process_instance_key, first.raw.businessId]).to eq([key, ""])
        first.mark_completed
        expect(raw_business_id_of("business-id-next-task", key)).to eq(assigned ? business_id : "")
      end

      it "fires call hooks filtered to the RPC" do
        calls = []
        Busybee.after_call(rpc: :assign_process_instance_business_id) { |call| calls << call.status }
        key = start

        begin
          client.assign_business_id(key, business_id)
        rescue Busybee::GRPC::Error
          nil # unimplemented before 8.10
        end
        expect(calls).to eq([gateway_at_least?("8.10") ? :succeeded : :errored])
      end
    end

    describe "completion" do
      let(:fixtures) { %w[business_id_process call_activity_parent call_activity_child] }

      # The instance's own business-id-task job, as a Busybee::Job.
      def with_task_job(key, type = "business-id-task", &)
        seen = false
        client.with_each_job(type, max_jobs: 1) do |job|
          expect(job.process_instance_key).to eq(key) if key
          seen = true
          yield job
        end
        expect(seen).to be(true)
      end

      def failed_precondition = a_kind_of(Busybee::GRPC::Error).and(have_attributes(grpc_status: :failed_precondition))

      it "assigns the business ID through client.complete_job on 8.10, and drops it before" do
        key = start
        with_task_job(key) { |job| client.complete_job(job.key, business_id: business_id) }

        expect(raw_business_id_of("business-id-next-task", key)).to eq(gateway_at_least?("8.10") ? business_id : "")
      end

      it "assigns a staged business ID with the job's own completion" do
        key = start
        with_task_job(key) do |job|
          expect(job.process_instance_business_id).to be_nil
          job.process_instance_business_id ||= business_id
          job.complete!
        end

        expect(raw_business_id_of("business-id-next-task", key)).to eq(gateway_at_least?("8.10") ? business_id : "")
      end

      it "assigns a staged business ID with a worker's auto-complete" do
        id = business_id
        worker = stub_const("BusinessIdStagingWorker", Class.new(Busybee::Worker) do
          job_type "business-id-task"
          define_method(:perform) { job.process_instance_business_id ||= id }
        end)
        key = start
        with_task_job(key) { |job| worker.perform_job(job) }

        expect(raw_business_id_of("business-id-next-task", key)).to eq(gateway_at_least?("8.10") ? id : "")
      end

      it "hands a job of an instance with a business ID the ID on 8.10, which refuses another" do
        key = start(business_id: business_id)
        with_task_job(key) do |job|
          next expect(job.process_instance_business_id).to be_nil unless gateway_at_least?("8.10")

          expect(job.process_instance_business_id).to eq(business_id)
          expect { job.process_instance_business_id = business_id }.to raise_error(Busybee::BusinessIdAlreadyAssigned)
          job.complete!
        end
      end

      it "rejects a completion carrying even the identical business ID once the instance has one, on 8.10" do
        key = start(business_id: business_id)
        with_task_job(key) do |job|
          if gateway_at_least?("8.10")
            expect { client.complete_job(job.key, business_id: business_id) }.
              to raise_error(failed_precondition)
            job.complete! # still open
          else
            client.complete_job(job.key, business_id: business_id)
          end
        end
      end

      it "rejects a completion staging a business ID from a call activity's child instance, on 8.10" do
        start("call-activity-parent", vars: { marker: business_id })
        with_task_job(nil, "call-activity-child-task") do |job|
          expect(job.variables[:marker]).to eq(business_id)
          job.process_instance_business_id = business_id
          if gateway_at_least?("8.10")
            expect { job.complete! }.to raise_error(failed_precondition)
            expect(job).to be_ready
          else
            job.complete!
          end
        end
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
