# frozen_string_literal: true

RSpec.describe Busybee::Worker::Configuration do
  # Helper to create a Configuration for a stub-const'd worker class
  def configuration_for(class_name)
    klass = stub_const(class_name, Class.new)
    described_class.new(klass)
  end

  describe "#job_type" do
    context "with default derivation from class name" do
      it "strips trailing Worker and underscores the remainder" do
        config = configuration_for("ProcessOrderWorker")
        expect(config.job_type).to eq("process_order")
      end

      it "uses only the last :: segment" do
        config = configuration_for("MyApp::Payments::RefundWorker")
        expect(config.job_type).to eq("refund")
      end

      it "underscores multi-word names without Worker suffix" do
        config = configuration_for("MyApp::SimpleTask")
        expect(config.job_type).to eq("simple_task")
      end

      it "handles a single-word class name without Worker suffix" do
        config = configuration_for("Notifier")
        expect(config.job_type).to eq("notifier")
      end

      it "handles a class named exactly Worker" do
        config = configuration_for("Worker")
        expect(config.job_type).to eq("worker")
      end

      it "handles acronym-style names" do
        config = configuration_for("HTTPSyncWorker")
        expect(config.job_type).to eq("http_sync")
      end
    end

    context "with explicit override" do
      it "accepts a string" do
        config = configuration_for("ProcessOrderWorker")
        config.job_type = "custom-type"
        expect(config.job_type).to eq("custom-type")
      end

      it "converts symbols to strings" do
        config = configuration_for("ProcessOrderWorker")
        config.job_type = :custom_type
        expect(config.job_type).to eq("custom_type")
      end
    end
  end

  describe "#description" do
    it "defaults to nil" do
      config = configuration_for("ProcessOrderWorker")
      expect(config.description).to be_nil
    end

    it "stores a description string" do
      config = configuration_for("ProcessOrderWorker")
      config.description = "Processes incoming orders"
      expect(config.description).to eq("Processes incoming orders")
    end
  end

  # Mission 8 will add DSL methods (input, output, runner_mode, polling, streaming,
  # job_timeout, backoff) that populate these collections and configuration values.
  # Mission 9 will add lifecycle configuration (autocomplete, autofail, unhealthy_on).

  describe "#inputs" do
    it "starts as an empty collection" do
      config = configuration_for("ProcessOrderWorker")
      expect(config.inputs).to eq([])
    end

    # Mission 8: input/variable/header DSL methods will add Input structs here
  end

  describe "#outputs" do
    it "starts as an empty collection" do
      config = configuration_for("ProcessOrderWorker")
      expect(config.outputs).to eq([])
    end

    # Mission 8: output DSL method will add Output structs here
  end

  describe Busybee::Worker::Configuration::Input do
    subject(:input) do
      described_class.new(
        name: :order_id,
        source: :variable,
        required: true,
        type: :uuid,
        description: "The order identifier",
        default: nil,
        accessor_name: nil,
        define_accessor: true
      )
    end

    it "stores name" do
      expect(input.name).to eq(:order_id)
    end

    it "stores source" do
      expect(input.source).to eq(:variable)
    end

    it "stores required" do
      expect(input.required).to be(true)
    end

    it "stores type" do
      expect(input.type).to eq(:uuid)
    end

    it "stores description" do
      expect(input.description).to eq("The order identifier")
    end

    it "stores default" do
      expect(input.default).to be_nil
    end

    it "stores accessor_name" do
      expect(input.accessor_name).to be_nil
    end

    it "stores define_accessor" do
      expect(input.define_accessor).to be(true)
    end

    it "supports multi-source inputs" do
      multi_input = described_class.new(
        name: :channel,
        source: %i[header variable],
        required: false,
        type: :string,
        description: nil,
        default: "email",
        accessor_name: nil,
        define_accessor: true
      )

      expect(multi_input.source).to eq(%i[header variable])
      expect(multi_input.default).to eq("email")
    end
  end

  describe Busybee::Worker::Configuration::Output do
    it "stores all output attributes" do
      output = described_class.new(
        name: :notification_id,
        required: true,
        type: :uuid,
        description: "The notification ID"
      )

      expect(output.name).to eq(:notification_id)
      expect(output.required).to be(true)
      expect(output.type).to eq(:uuid)
      expect(output.description).to eq("The notification ID")
    end
  end

  describe "#to_h" do
    it "serializes configuration to a hash" do
      config = configuration_for("ProcessOrderWorker")
      config.description = "Processes orders"

      result = config.to_h

      expect(result[:job_type]).to eq("process_order")
      expect(result[:description]).to eq("Processes orders")
      expect(result[:inputs]).to eq([])
      expect(result[:outputs]).to eq([])
    end

    # Mission 8: to_h will include DSL-configured values (runner_mode, polling, etc.)
    # Mission 9: to_h will include lifecycle values (autocomplete, autofail, unhealthy_on)
  end
end
