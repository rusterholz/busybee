# frozen_string_literal: true

require "active_support/core_ext/numeric/time"

RSpec.describe Busybee::Job do
  let(:client) { instance_double(Busybee::Client) }

  let(:raw_job) do
    # Using plain double since protobuf generates accessors dynamically.
    # Field names verified against proto/gateway.proto ActivatedJob message.
    # rubocop:disable RSpec/VerifiedDoubles
    double(
      "Busybee::GRPC::ActivatedJob",
      key: 123456,
      type: "find_available_driver",
      processInstanceKey: 789012,
      bpmnProcessId: "assign_delivery_driver",
      processDefinitionKey: 345678,
      elementId: "task-find-driver",
      elementInstanceKey: 901234,
      customHeaders: '{"priority":"high"}',
      worker: "worker-1",
      retries: 3,
      deadline: 1640000000000,
      variables: "{\"order\":{\"id\":\"550e8400-e29b-41d4-a716-446655440000\",\"amount\":99.99," \
                 "\"customerName\":\"Jane Doe\"},\"processTimeout\":\"PT1H\"}"
    )
    # rubocop:enable RSpec/VerifiedDoubles
  end

  let(:job) { described_class.new(raw_job, client: client) }

  describe "#initialize" do
    it "wraps a raw job protobuf" do
      expect(job).to be_a(described_class)
    end

    it "initializes with :ready status" do
      expect(job.status).to eq(:ready)
    end

    it "requires a client parameter" do
      expect { described_class.new(raw_job) }.to raise_error(ArgumentError)
    end
  end

  describe "delegation to raw job" do
    it "delegates #key to raw job" do
      expect(job.key).to eq(123456)
    end

    it "delegates #type to raw job" do
      expect(job.type).to eq("find_available_driver")
    end

    it "delegates #process_instance_key to raw job" do
      expect(job.process_instance_key).to eq(789012)
    end

    it "delegates #bpmn_process_id to raw job" do
      expect(job.bpmn_process_id).to eq("assign_delivery_driver")
    end

    it "delegates #retries to raw job" do
      expect(job.retries).to eq(3)
    end

    it "returns deadline as a Time object" do
      expect(job.deadline).to be_a(Time)
      expect(job.deadline).to eq(Time.at(1640000000))
    end

    it "freezes the deadline" do
      expect(job.deadline).to be_frozen
    end

    it "memoizes the deadline" do
      deadline1 = job.deadline
      deadline2 = job.deadline
      expect(deadline1.object_id).to eq(deadline2.object_id)
    end
  end

  describe "#variables" do
    it "parses JSON variables into HashWithIndifferentAccess" do
      vars = job.variables
      expect(vars).to be_a(ActiveSupport::HashWithIndifferentAccess)
      expect(vars[:processTimeout]).to eq("PT1H")
      expect(vars["processTimeout"]).to eq("PT1H")
    end

    it "supports nested hash access with indifferent access" do
      expect(job.variables[:order][:id]).to eq("550e8400-e29b-41d4-a716-446655440000")
      expect(job.variables["order"]["id"]).to eq("550e8400-e29b-41d4-a716-446655440000")
      expect(job.variables[:order]["amount"]).to eq(99.99)
      expect(job.variables["order"][:customerName]).to eq("Jane Doe")
    end

    it "supports method-style access with snake_case conversion" do
      expect(job.variables.process_timeout).to eq("PT1H")
      expect(job.variables.order.id).to eq("550e8400-e29b-41d4-a716-446655440000")
      expect(job.variables.order.amount).to eq(99.99)
      expect(job.variables.order.customer_name).to eq("Jane Doe")
    end

    it "chains HashAccess mixin recursively to nested hashes" do
      order = job.variables.order
      expect(order).to be_a(ActiveSupport::HashWithIndifferentAccess)
      expect(order).to respond_to(:customer_name)
      expect(order.customer_name).to eq("Jane Doe")
    end

    it "raises NoMethodError for non-existent keys via method access" do
      expect { job.variables.non_existent_key }.to raise_error(NoMethodError)
    end

    it "freezes the returned hash" do
      expect(job.variables).to be_frozen
    end

    it "recursively freezes nested hashes" do
      expect(job.variables[:order]).to be_frozen
    end

    it "prevents modification of variables" do
      expect { job.variables[:newKey] = "value" }.to raise_error(FrozenError)
    end

    it "prevents modification of nested variables" do
      expect { job.variables[:order][:newKey] = "value" }.to raise_error(FrozenError)
    end

    it "memoizes parsed variables" do
      vars1 = job.variables
      vars2 = job.variables
      expect(vars1.object_id).to eq(vars2.object_id)
    end

    context "when variables is nil" do
      let(:raw_job) do
        double( # rubocop:disable RSpec/VerifiedDoubles
          "Busybee::GRPC::ActivatedJob",
          key: 123456,
          type: "test",
          processInstanceKey: 789012,
          bpmnProcessId: "test-workflow",
          retries: 3,
          deadline: 1640000000000,
          customHeaders: "{}",
          variables: nil
        )
      end

      it "returns empty frozen hash" do
        vars = job.variables
        expect(vars).to eq({})
        expect(vars).to be_frozen
        expect(vars).to be_a(ActiveSupport::HashWithIndifferentAccess)
      end
    end

    context "when variables is empty string" do
      let(:raw_job) do
        double( # rubocop:disable RSpec/VerifiedDoubles
          "Busybee::GRPC::ActivatedJob",
          key: 123456,
          type: "test",
          processInstanceKey: 789012,
          bpmnProcessId: "test-workflow",
          retries: 3,
          deadline: 1640000000000,
          customHeaders: "{}",
          variables: ""
        )
      end

      it "returns empty frozen hash" do
        vars = job.variables
        expect(vars).to eq({})
        expect(vars).to be_frozen
        expect(vars).to be_a(ActiveSupport::HashWithIndifferentAccess)
      end
    end

    context "when variables JSON is invalid" do
      let(:raw_job) do
        double( # rubocop:disable RSpec/VerifiedDoubles
          "Busybee::GRPC::ActivatedJob",
          key: 123456,
          type: "test",
          processInstanceKey: 789012,
          bpmnProcessId: "test-workflow",
          retries: 3,
          deadline: 1640000000000,
          customHeaders: "{}",
          variables: "{invalid json"
        )
      end

      it "raises Busybee::InvalidJobJson" do
        expect { job.variables }.to raise_error(Busybee::InvalidJobJson, /failed to parse job variables/i)
      end

      it "wraps the original JSON::ParserError" do
        job.variables
      rescue Busybee::InvalidJobJson => e
        expect(e.cause).to be_a(JSON::ParserError)
      end
    end
  end

  describe "#headers" do
    it "parses JSON custom headers into HashWithIndifferentAccess" do
      headers = job.headers
      expect(headers).to be_a(ActiveSupport::HashWithIndifferentAccess)
      expect(headers[:priority]).to eq("high")
      expect(headers["priority"]).to eq("high")
    end

    it "supports method-style access with snake_case conversion" do
      # Add a header with camelCase to test conversion
      raw_job_with_camel = double( # rubocop:disable RSpec/VerifiedDoubles
        "Busybee::GRPC::ActivatedJob",
        key: 123456,
        type: "test",
        processInstanceKey: 789012,
        bpmnProcessId: "test-workflow",
        retries: 3,
        deadline: 1640000000000,
        variables: "{}",
        customHeaders: '{"maxRetries":5}'
      )
      test_job = described_class.new(raw_job_with_camel, client: client)
      expect(test_job.headers.max_retries).to eq(5)
    end

    it "freezes the returned hash" do
      expect(job.headers).to be_frozen
    end

    it "prevents modification of headers" do
      expect { job.headers[:newKey] = "value" }.to raise_error(FrozenError)
    end

    it "memoizes parsed headers" do
      headers1 = job.headers
      headers2 = job.headers
      expect(headers1.object_id).to eq(headers2.object_id)
    end

    context "when customHeaders is nil" do
      let(:raw_job) do
        double( # rubocop:disable RSpec/VerifiedDoubles
          "Busybee::GRPC::ActivatedJob",
          key: 123456,
          type: "test",
          processInstanceKey: 789012,
          bpmnProcessId: "test-workflow",
          retries: 3,
          deadline: 1640000000000,
          variables: "{}",
          customHeaders: nil
        )
      end

      it "returns empty frozen hash" do
        headers = job.headers
        expect(headers).to eq({})
        expect(headers).to be_frozen
        expect(headers).to be_a(ActiveSupport::HashWithIndifferentAccess)
      end
    end

    context "when customHeaders is empty string" do
      let(:raw_job) do
        double( # rubocop:disable RSpec/VerifiedDoubles
          "Busybee::GRPC::ActivatedJob",
          key: 123456,
          type: "test",
          processInstanceKey: 789012,
          bpmnProcessId: "test-workflow",
          retries: 3,
          deadline: 1640000000000,
          variables: "{}",
          customHeaders: ""
        )
      end

      it "returns empty frozen hash" do
        headers = job.headers
        expect(headers).to eq({})
        expect(headers).to be_frozen
        expect(headers).to be_a(ActiveSupport::HashWithIndifferentAccess)
      end
    end

    context "when customHeaders JSON is invalid" do
      let(:raw_job) do
        double( # rubocop:disable RSpec/VerifiedDoubles
          "Busybee::GRPC::ActivatedJob",
          key: 123456,
          type: "test",
          processInstanceKey: 789012,
          bpmnProcessId: "test-workflow",
          retries: 3,
          deadline: 1640000000000,
          variables: "{}",
          customHeaders: "{invalid json"
        )
      end

      it "raises Busybee::InvalidJobJson" do
        expect { job.headers }.to raise_error(Busybee::InvalidJobJson, /failed to parse job headers/i)
      end

      it "wraps the original JSON::ParserError" do
        job.headers
      rescue Busybee::InvalidJobJson => e
        expect(e.cause).to be_a(JSON::ParserError)
      end
    end
  end

  describe "status predicates" do
    describe "#ready?" do
      it "returns true when status is :ready" do
        expect(job).to be_ready
      end

      it "returns false when status is :complete" do
        allow(job).to receive(:status).and_return(:complete)
        expect(job).not_to be_ready
      end

      it "returns false when status is :failed" do
        allow(job).to receive(:status).and_return(:failed)
        expect(job).not_to be_ready
      end

      it "returns false when status is :error" do
        allow(job).to receive(:status).and_return(:error)
        expect(job).not_to be_ready
      end
    end

    describe "#complete?" do
      it "returns false when status is :ready" do
        expect(job).not_to be_complete
      end

      it "returns true when status is :complete" do
        allow(job).to receive(:status).and_return(:complete)
        expect(job).to be_complete
      end
    end

    describe "#failed?" do
      it "returns false when status is :ready" do
        expect(job).not_to be_failed
      end

      it "returns true when status is :failed" do
        allow(job).to receive(:status).and_return(:failed)
        expect(job).to be_failed
      end
    end

    describe "#error?" do
      it "returns false when status is :ready" do
        expect(job).not_to be_error
      end

      it "returns true when status is :error" do
        allow(job).to receive(:status).and_return(:error)
        expect(job).to be_error
      end
    end
  end

  describe "#complete!" do
    context "when job is ready" do
      it "calls client.complete_job with job key and variables" do
        allow(client).to receive(:complete_job)

        job.complete!(result: "success")

        expect(client).to have_received(:complete_job).with(123456, vars: { result: "success" })
      end

      it "defaults to empty hash when no variables provided" do
        allow(client).to receive(:complete_job)

        job.complete!

        expect(client).to have_received(:complete_job).with(123456, vars: {})
      end

      it "changes status to :complete" do
        allow(client).to receive(:complete_job)

        expect { job.complete! }.to change(job, :status).from(:ready).to(:complete)
      end

      it "returns truthy value" do
        allow(client).to receive(:complete_job).and_return(true)

        expect(job.complete!).to be_truthy
      end
    end

    context "when job is already complete" do
      before do
        allow(client).to receive(:complete_job)
        job.complete!
      end

      it "raises Busybee::JobAlreadyHandled" do
        expect { job.complete! }.to raise_error(
          Busybee::JobAlreadyHandled,
          /cannot complete job.*already complete/i
        )
      end
    end

    context "when job is already failed" do
      before do
        allow(client).to receive(:fail_job)
        job.fail!("Error")
      end

      it "raises Busybee::JobAlreadyHandled" do
        expect { job.complete! }.to raise_error(
          Busybee::JobAlreadyHandled,
          /cannot complete job.*already failed/i
        )
      end
    end

    context "when job is already in error state" do
      before do
        allow(client).to receive(:throw_bpmn_error)
        job.throw_bpmn_error!("ERROR_CODE")
      end

      it "raises Busybee::JobAlreadyHandled" do
        expect { job.complete! }.to raise_error(
          Busybee::JobAlreadyHandled,
          /cannot complete job.*already error/i
        )
      end
    end
  end

  describe "#fail!" do
    context "when job is ready" do
      it "calls client.fail_job with job key and error message" do
        allow(client).to receive(:fail_job)

        job.fail!("Something went wrong")

        expect(client).to have_received(:fail_job).with(
          123456,
          "Something went wrong",
          retries: nil,
          backoff: nil
        )
      end

      it "passes through optional retries parameter" do
        allow(client).to receive(:fail_job)

        job.fail!("Error", retries: 5)

        expect(client).to have_received(:fail_job).with(
          123456,
          "Error",
          retries: 5,
          backoff: nil
        )
      end

      it "passes through optional backoff parameter as integer" do
        allow(client).to receive(:fail_job)

        job.fail!("Error", backoff: 5000)

        expect(client).to have_received(:fail_job).with(
          123456,
          "Error",
          retries: nil,
          backoff: 5000
        )
      end

      it "passes through optional backoff parameter as Duration" do
        duration = 5.seconds
        allow(client).to receive(:fail_job)

        job.fail!("Error", backoff: duration)

        expect(client).to have_received(:fail_job).with(
          123456,
          "Error",
          retries: nil,
          backoff: duration
        )
      end

      it "changes status to :failed" do
        allow(client).to receive(:fail_job)

        expect { job.fail!("Error") }.to change(job, :status).from(:ready).to(:failed)
      end

      it "returns truthy value" do
        allow(client).to receive(:fail_job).and_return(true)

        expect(job.fail!("Error")).to be_truthy
      end

      context "when passed an exception" do
        let(:error) { StandardError.new("Something broke") }

        it "formats message as [ExceptionClass] message" do
          allow(client).to receive(:fail_job)

          job.fail!(error)

          expect(client).to have_received(:fail_job).with(
            123456,
            "[StandardError] Something broke",
            retries: nil,
            backoff: nil
          )
        end

        context "when exception has a cause" do
          let(:error) do
            begin
              raise ArgumentError, "Invalid input"
            rescue ArgumentError
              raise StandardError, "Something broke"
            end
          rescue StandardError => e
            e
          end

          it "appends cause information" do
            allow(client).to receive(:fail_job)

            job.fail!(error)

            expect(client).to have_received(:fail_job).with(
              123456,
              "[StandardError] Something broke (caused by: [ArgumentError] Invalid input)",
              retries: nil,
              backoff: nil
            )
          end
        end
      end
    end

    context "when job is already complete" do
      before do
        allow(client).to receive(:complete_job)
        job.complete!
      end

      it "raises Busybee::JobAlreadyHandled" do
        expect { job.fail!("Error") }.to raise_error(
          Busybee::JobAlreadyHandled,
          /cannot fail job.*already complete/i
        )
      end
    end

    context "when job is already failed" do
      before do
        allow(client).to receive(:fail_job)
        job.fail!("Error")
      end

      it "raises Busybee::JobAlreadyHandled" do
        expect { job.fail!("Error") }.to raise_error(
          Busybee::JobAlreadyHandled,
          /cannot fail job.*already failed/i
        )
      end
    end
  end

  describe "#throw_bpmn_error!" do
    context "when job is ready" do
      it "calls client.throw_bpmn_error with job key and error code string" do
        allow(client).to receive(:throw_bpmn_error)

        job.throw_bpmn_error!("ORDER_NOT_FOUND")

        expect(client).to have_received(:throw_bpmn_error).with(
          123456,
          "ORDER_NOT_FOUND",
          message: ""
        )
      end

      it "passes through optional message parameter" do
        allow(client).to receive(:throw_bpmn_error)

        job.throw_bpmn_error!("ORDER_NOT_FOUND", "Order 550e8400 not found in database")

        expect(client).to have_received(:throw_bpmn_error).with(
          123456,
          "ORDER_NOT_FOUND",
          message: "Order 550e8400 not found in database"
        )
      end

      it "converts snake_case symbol to UPPERCASE_SNAKE_CASE string" do
        allow(client).to receive(:throw_bpmn_error)

        job.throw_bpmn_error!(:order_not_found)

        expect(client).to have_received(:throw_bpmn_error).with(
          123456,
          "ORDER_NOT_FOUND",
          message: ""
        )
      end

      it "converts snake_case symbol with message" do
        allow(client).to receive(:throw_bpmn_error)

        job.throw_bpmn_error!(:payment_failed, "Insufficient funds")

        expect(client).to have_received(:throw_bpmn_error).with(
          123456,
          "PAYMENT_FAILED",
          message: "Insufficient funds"
        )
      end

      context "when passed an exception" do
        let(:error) { Class.new(StandardError).new("Order not found") }

        before do
          stub_const("OrderNotFoundError", error.class)
        end

        it "converts exception class name to error code" do
          allow(client).to receive(:throw_bpmn_error)

          job.throw_bpmn_error!(error)

          expect(client).to have_received(:throw_bpmn_error).with(
            123456,
            "ORDER_NOT_FOUND_ERROR",
            message: "Order not found"
          )
        end
      end

      context "when passed a namespaced exception" do
        let(:error) { Class.new(StandardError).new("Invalid state") }

        before do
          stub_const("MyApp::Domain::InvalidStateError", error.class)
        end

        it "converts fully-qualified exception class name to error code" do
          allow(client).to receive(:throw_bpmn_error)

          job.throw_bpmn_error!(error)

          expect(client).to have_received(:throw_bpmn_error).with(
            123456,
            "MY_APP_DOMAIN_INVALID_STATE_ERROR",
            message: "Invalid state"
          )
        end
      end

      it "changes status to :error" do
        allow(client).to receive(:throw_bpmn_error)

        expect { job.throw_bpmn_error!("ERROR_CODE") }.to change(job, :status).from(:ready).to(:error)
      end

      it "returns truthy value" do
        allow(client).to receive(:throw_bpmn_error).and_return(true)

        expect(job.throw_bpmn_error!("ERROR_CODE")).to be_truthy
      end
    end

    context "when job is already complete" do
      before do
        allow(client).to receive(:complete_job)
        job.complete!
      end

      it "raises Busybee::JobAlreadyHandled" do
        expect { job.throw_bpmn_error!("ERROR_CODE") }.to raise_error(
          Busybee::JobAlreadyHandled,
          /cannot throw bpmn error.*already complete/i
        )
      end
    end

    context "when job is already failed" do
      before do
        allow(client).to receive(:fail_job)
        job.fail!("Error")
      end

      it "raises Busybee::JobAlreadyHandled" do
        expect { job.throw_bpmn_error!("ERROR_CODE") }.to raise_error(
          Busybee::JobAlreadyHandled,
          /cannot throw bpmn error.*already failed/i
        )
      end
    end

    context "when job is already in error state" do
      before do
        allow(client).to receive(:throw_bpmn_error)
        job.throw_bpmn_error!("ERROR_CODE")
      end

      it "raises Busybee::JobAlreadyHandled" do
        expect { job.throw_bpmn_error!("ERROR_CODE") }.to raise_error(
          Busybee::JobAlreadyHandled,
          /cannot throw bpmn error.*already error/i
        )
      end
    end
  end
end
