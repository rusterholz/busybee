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

  describe "#client" do
    it "returns the client instance" do
      expect(job.client).to be(client)
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

    it "delegates #element_id to raw job" do
      expect(job.element_id).to eq("task-find-driver")
    end

    it "delegates #retries to raw job" do
      expect(job.retries).to eq(3)
    end

    it "returns deadline as a UTC Time object" do
      expect(job.deadline).to be_a(Time)
      expect(job.deadline).to eq(Time.at(1640000000))
      expect(job.deadline).to be_utc
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
        job.send(:resolution).resolve_to(:complete)
        expect(job).not_to be_ready
      end

      it "returns false when status is :failed" do
        job.send(:resolution).resolve_to(:failed)
        expect(job).not_to be_ready
      end

      it "returns false when status is :error" do
        job.send(:resolution).resolve_to(:error)
        expect(job).not_to be_ready
      end
    end

    describe "#complete?" do
      it "returns false when status is :ready" do
        expect(job).not_to be_complete
      end

      it "returns true when status is :complete" do
        job.send(:resolution).resolve_to(:complete)
        expect(job).to be_complete
      end
    end

    describe "#failed?" do
      it "returns false when status is :ready" do
        expect(job).not_to be_failed
      end

      it "returns true when status is :failed" do
        job.send(:resolution).resolve_to(:failed)
        expect(job).to be_failed
      end
    end

    describe "#error?" do
      it "returns false when status is :ready" do
        expect(job).not_to be_error
      end

      it "returns true when status is :error" do
        job.send(:resolution).resolve_to(:error)
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

      it "captures the formatted error message to Resolution" do
        allow(client).to receive(:fail_job)

        job.fail!("Something went wrong")

        expect(job.send(:resolution).error_message).to eq("Something went wrong")
      end

      it "captures the exception to Resolution when passed an exception" do
        allow(client).to receive(:fail_job)
        err = StandardError.new("boom")

        job.fail!(err)

        expect(job.error).to be(err)
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

    context "when client.fail_job raises mid-call" do
      before { allow(client).to receive(:fail_job).and_raise(StandardError.new("grpc down")) }

      it "leaves the error captured on Resolution with status still :ready" do
        err = StandardError.new("original")

        expect { job.fail!(err) }.to raise_error(StandardError, "grpc down")

        expect(job.error).to be(err)
        expect(job.status).to eq(:ready)
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

      it "captures error_code and error_message to Resolution" do
        allow(client).to receive(:throw_bpmn_error)

        job.throw_bpmn_error!(:order_not_found, "Order 550e8400 not found")

        expect(job.error_code).to eq("ORDER_NOT_FOUND")
        expect(job.send(:resolution).error_message).to eq("Order 550e8400 not found")
      end

      it "captures the exception to Resolution when given one" do
        stub_const("OrderNotFoundError", Class.new(StandardError))
        err = OrderNotFoundError.new("Order 550e8400 not found")
        allow(client).to receive(:throw_bpmn_error)

        job.throw_bpmn_error!(err)

        expect(job.error).to be(err)
        expect(job.error_code).to eq("ORDER_NOT_FOUND_ERROR")
        expect(job.send(:resolution).error_message).to eq("Order 550e8400 not found")
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

    context "when client.throw_bpmn_error raises mid-call" do
      before { allow(client).to receive(:throw_bpmn_error).and_raise(StandardError.new("grpc down")) }

      it "leaves the error data captured on Resolution with status still :ready" do
        expect { job.throw_bpmn_error!(:order_not_found, "missing") }.to raise_error(StandardError, "grpc down")

        expect(job.error_code).to eq("ORDER_NOT_FOUND")
        expect(job.send(:resolution).error_message).to eq("missing")
        expect(job.status).to eq(:ready)
      end
    end
  end

  describe "status-change prevention" do
    describe "#_prevent_status_changes!" do
      it "causes #complete! to raise StatusChangeOutsidePerform" do
        allow(client).to receive(:complete_job)
        job._prevent_status_changes!

        expect { job.complete! }.to raise_error(
          Busybee::StatusChangeOutsidePerform,
          /outside perform/i
        )
      end

      it "causes #fail! to raise StatusChangeOutsidePerform" do
        allow(client).to receive(:fail_job)
        job._prevent_status_changes!

        expect { job.fail!("boom") }.to raise_error(
          Busybee::StatusChangeOutsidePerform,
          /outside perform/i
        )
      end

      it "causes #throw_bpmn_error! to raise StatusChangeOutsidePerform" do
        allow(client).to receive(:throw_bpmn_error)
        job._prevent_status_changes!

        expect { job.throw_bpmn_error!(:some_code) }.to raise_error(
          Busybee::StatusChangeOutsidePerform,
          /outside perform/i
        )
      end

      it "does not change status when raising" do
        allow(client).to receive(:complete_job)
        job._prevent_status_changes!

        expect { job.complete! rescue nil }.not_to change(job, :status) # rubocop:disable Style/RescueModifier
      end
    end

    describe "#_allow_status_changes!" do
      it "re-enables status changes after prevention" do
        allow(client).to receive(:complete_job)
        job._prevent_status_changes!
        job._allow_status_changes!

        expect { job.complete! }.not_to raise_error
      end
    end
  end

  describe "does not fire job lifecycle hooks" do
    # complete!/fail!/throw_bpmn_error! perform the gRPC call and update
    # the Resolution PORO. Hook firing (including after_job) is a
    # Worker.perform_job concern — one ensure block, post-perform. These
    # methods invoke no hook callbacks themselves, so they also cannot
    # raise Busybee::Worker::Shutdown even with a shutdown_on-classed
    # after_job hook registered.
    after { Busybee::Hooks.reset! }

    it "#complete! does not fire after_job" do
      allow(client).to receive(:complete_job)
      invocations = 0
      Busybee.after_job { invocations += 1 }

      job.complete!

      expect(invocations).to eq(0)
    end

    it "#fail! does not fire after_job" do
      allow(client).to receive(:fail_job)
      invocations = 0
      Busybee.after_job { invocations += 1 }

      job.fail!("boom")

      expect(invocations).to eq(0)
    end

    it "#throw_bpmn_error! does not fire after_job" do
      allow(client).to receive(:throw_bpmn_error)
      invocations = 0
      Busybee.after_job { invocations += 1 }

      job.throw_bpmn_error!(:some_code)

      expect(invocations).to eq(0)
    end
  end

  describe "#update_retries" do
    it "calls client.update_job_retries with job key and count" do
      allow(client).to receive(:update_job_retries)

      job.update_retries(5)

      expect(client).to have_received(:update_job_retries).with(123456, 5)
    end

    it "updates the local retries value" do
      allow(client).to receive(:update_job_retries)

      expect { job.update_retries(5) }.to change(job, :retries).from(3).to(5)
    end

    it "does not change job status" do
      allow(client).to receive(:update_job_retries)

      expect { job.update_retries(5) }.not_to change(job, :status)
    end
  end

  describe "#update_timeout" do
    it "calls client.update_job_timeout with job key and duration" do
      allow(client).to receive(:update_job_timeout)

      job.update_timeout(30_000)

      expect(client).to have_received(:update_job_timeout).with(123456, 30_000)
    end

    it "passes through Duration objects" do
      duration = 30.seconds
      allow(client).to receive(:update_job_timeout)

      job.update_timeout(duration)

      expect(client).to have_received(:update_job_timeout).with(123456, duration)
    end

    it "updates the local deadline from integer milliseconds" do
      allow(client).to receive(:update_job_timeout)
      freeze_time = Time.now.utc

      allow(Time).to receive(:now).and_return(freeze_time)
      job.update_timeout(30_000)

      expect(job.deadline).to eq(freeze_time + 30)
      expect(job.deadline).to be_utc
      expect(job.deadline).to be_frozen
    end

    it "updates the local deadline from Duration" do
      allow(client).to receive(:update_job_timeout)
      freeze_time = Time.now.utc

      allow(Time).to receive(:now).and_return(freeze_time)
      job.update_timeout(30.seconds)

      expect(job.deadline).to eq(freeze_time + 30)
    end

    it "does not change job status" do
      allow(client).to receive(:update_job_timeout)

      expect { job.update_timeout(30_000) }.not_to change(job, :status)
    end
  end

  describe "timestamps" do
    describe "#stamp!" do
      it "sets both monotonic and UTC timestamps" do
        job.timestamps.stamp!(:activated_at)

        expect(job.activated_at(:monotonic)).to be_a(Float)
        expect(job.activated_at).to be_a(Time)
        expect(job.activated_at).to be_utc
      end

      it "returns self for chaining" do
        expect(job.timestamps.stamp!(:activated_at)).to be(job.timestamps)
      end

      it "uses monotonic clock for the base timestamp" do
        before = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        job.timestamps.stamp!(:activated_at)
        after = Process.clock_gettime(Process::CLOCK_MONOTONIC)

        expect(job.activated_at(:monotonic)).to be_between(before, after)
      end

      it "captures UTC wall clock for the utc timestamp" do
        before = Time.now.utc
        job.timestamps.stamp!(:activated_at)
        after = Time.now.utc

        expect(job.activated_at).to be_between(before, after)
      end

      it "raises for unknown timestamp names" do
        expect { job.timestamps.stamp!(:bogus_at) }.to raise_error(ArgumentError, /bogus_at/)
      end
    end

    describe "timestamp accessors" do
      it "returns nil before stamping" do
        %i[activated_at execution_started_at perform_started_at
           perform_finished_at resolved_at executed_at].each do |name|
          expect(job.public_send(name)).to be_nil, "expected #{name} to be nil"
          expect(job.public_send(name, :monotonic)).to be_nil, "expected #{name}(:monotonic) to be nil"
        end
      end

      it "supports all six timestamp pairs" do
        %i[activated_at execution_started_at perform_started_at
           perform_finished_at resolved_at executed_at].each do |name|
          job.timestamps.stamp!(name)
          expect(job.public_send(name, :monotonic)).to be_a(Float), "expected #{name}(:monotonic) to be Float"
          expect(job.public_send(name)).to be_a(Time), "expected #{name} to be Time"
        end
      end
    end
  end

  describe "predicate aliases (Phase 2 hook surface)" do
    it "exposes completed? as an alias for complete?" do
      job.send(:resolution).resolve_to(:complete)
      expect(job).to be_completed
    end

    it "exposes errored? as an alias for error?" do
      job.send(:resolution).resolve_to(:error)
      expect(job).to be_errored
    end
  end

  describe "#error_message" do
    it "returns the explicit error_message when set" do
      job.send(:resolution).resolve_to(:failed)
      job.send(:resolution).set_error(error_message: "explicit")
      expect(job.error_message).to eq("explicit")
    end

    it "falls back to error.message when error_message is unset" do
      job.send(:resolution).resolve_to(:failed)
      job.send(:resolution).set_error(RuntimeError.new("from-error"))
      expect(job.error_message).to eq("from-error")
    end

    it "is nil when both are unset" do
      expect(job.error_message).to be_nil
    end
  end

  describe "computed durations" do
    {
      perform_duration_ms: %i[perform_started_at perform_finished_at],
      resolution_duration_ms: %i[execution_started_at resolved_at],
      execution_duration_ms: %i[execution_started_at executed_at],
      buffer_latency_ms: %i[activated_at execution_started_at],
      total_duration_ms: %i[activated_at resolved_at],
      post_resolution_ms: %i[resolved_at executed_at],
      setup_duration_ms: %i[execution_started_at perform_started_at]
    }.each do |duration_method, (from, to)|
      describe "##{duration_method}" do
        it "is a positive Float when both #{from} and #{to} are stamped" do
          job.timestamps.stamp!(from)
          sleep 0.001
          job.timestamps.stamp!(to)

          expect(job.public_send(duration_method)).to be_a(Float)
          expect(job.public_send(duration_method)).to be > 0
        end

        it "is nil when #{from} is missing" do
          job.timestamps.stamp!(to)
          expect(job.public_send(duration_method)).to be_nil
        end

        it "is nil when #{to} is missing" do
          job.timestamps.stamp!(from)
          expect(job.public_send(duration_method)).to be_nil
        end
      end
    end
  end

  describe "#set_context" do
    it "routes activation-owned keys into Activation" do
      worker_class = stub_const("RouteWorker", Class.new)
      job.set_context(source: :poll, worker: worker_class.allocate)

      expect(job.source).to eq(:poll)
      expect(job.worker_class).to eq(worker_class)
    end

    it "lands non-owned keys in Context as scratch" do
      job.set_context(span: "trace-span", correlation_id: "abc")

      expect(job.context[:span]).to eq("trace-span")
      expect(job.context[:correlation_id]).to eq("abc")
    end

    it "returns self for chaining" do
      expect(job.set_context(foo: 1)).to be(job)
    end

    context "with Resolution-owned keys (the reservation list)" do
      let(:logger) { instance_double(Logger, warn: nil) }

      before { allow(Busybee).to receive(:logger).and_return(logger) }

      Busybee::Job::Resolution::OWNED_KEYS.each do |key|
        it "drops :#{key} from Context and Resolution (it has a dedicated lifecycle method)" do
          job.set_context(key => :sentinel, foo: 1)

          aggregate_failures do
            expect(job.context[key]).to be_nil
            expect(job.context[:foo]).to eq(1)
            expect(job.status).to eq(:ready)
            expect(job.result).to be_nil
            expect(job.error).to be_nil
            expect(job.send(:resolution).error_code).to be_nil
            expect(job.send(:resolution).error_message).to be_nil
          end
        end

        it "logs a warning naming :#{key} and pointing at the lifecycle methods" do
          job.set_context(key => :sentinel)

          expect(logger).to have_received(:warn).with(/:#{key}/)
          expect(logger).to have_received(:warn).with(/complete!.*fail!.*throw_bpmn_error!/)
        end
      end

      it "warns once per reserved key passed in a single call" do
        job.set_context(status: :complete, result: { x: 1 }, error_code: "X", foo: 1)

        expect(logger).to have_received(:warn).with(/:status/).once
        expect(logger).to have_received(:warn).with(/:result/).once
        expect(logger).to have_received(:warn).with(/:error_code/).once
        expect(job.context[:foo]).to eq(1)
      end
    end
  end

  describe "#context_tags" do
    it "merges raw payload + activation + resolution + timestamps + context tags" do
      worker_class = stub_const("AggWorker", Class.new)
      job.set_context(source: :poll, worker: worker_class.allocate)
      job.send(:resolution).resolve_to(:complete)
      job.context[:user_tier] = "premium" # context_tags drops this

      expect(job.context_tags).to include(
        job_type: job.type,
        bpmn_process_id: job.bpmn_process_id,
        source: :poll,
        worker_class: "AggWorker",
        status: :complete
      )
      expect(job.context_tags).not_to have_key(:user_tier)
    end

    it "reflects the update_retries override, not the activation-time value" do
      allow(client).to receive(:update_job_retries)
      job.update_retries(5)

      expect(job.context_tags[:retries]).to eq(5)
    end
  end

  describe "#logging_context" do
    it "is a strict superset of context_tags" do
      job.set_context(source: :stream, buffer_size: 3)
      job.send(:resolution).resolve_to(:complete)
      job.context[:correlation_id] = "abc-123"
      job.context[:span] = Object.new # logging_context drops this

      tags = job.context_tags
      logging = job.logging_context

      tags.each do |key, value|
        expect(logging[key]).to eq(value), "expected logging_context[#{key.inspect}] to mirror context_tags"
      end
      expect(logging[:job_key]).to eq(job.key) # high-card, logging-only
      expect(logging[:buffer_size]).to eq(3)
      expect(logging[:correlation_id]).to eq("abc-123") # primitive scratch
      expect(logging).not_to have_key(:span) # complex object dropped
    end

    it "reflects the update_timeout override in deadline" do
      allow(client).to receive(:update_job_timeout)
      original = job.logging_context[:deadline]
      job.update_timeout(60_000)

      expect(job.logging_context[:deadline]).to eq(job.deadline)
      expect(job.logging_context[:deadline]).not_to eq(original)
    end
  end
end
