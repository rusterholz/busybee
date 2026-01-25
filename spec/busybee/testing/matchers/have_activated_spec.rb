# frozen_string_literal: true

require "busybee/testing/matchers/have_activated"
require "busybee/testing/helpers"

RSpec.describe "have_activated matcher" do
  let(:test_class) do
    Class.new do
      include Busybee::Testing::Helpers
    end
  end
  let(:helper) { test_class.new }
  let(:mock_client) { instance_double(Busybee::GRPC::Gateway::Stub) }

  # Shared declarations with overridable attributes
  let(:variables_json) { '{"foo": "bar"}' }
  let(:custom_headers_json) { '{"workflow_version": "v2"}' }
  let(:raw_job) do
    double( # rubocop:disable RSpec/VerifiedDoubles
      "Busybee::GRPC::ActivatedJob",
      key: 1,
      processInstanceKey: 2,
      variables: variables_json,
      customHeaders: custom_headers_json,
      retries: 3
    )
  end
  let(:jobs) { [raw_job] }
  let(:activate_response) { double("Busybee::GRPC::ActivateJobsResponse", jobs: jobs) } # rubocop:disable RSpec/VerifiedDoubles

  before do
    allow(Busybee::Testing::Helpers).to receive(:grpc_client).and_return(mock_client)
    allow(mock_client).to receive(:activate_jobs).and_return([activate_response])
  end

  describe "basic job activation checking" do
    it "passes when job type was activated" do
      expect(helper).to have_activated("my-task")
    end

    context "when no job was activated" do
      let(:jobs) { [] }

      it "fails with helpful message" do
        expect do
          expect(helper).to have_activated("my-task")
        end.to raise_error(RSpec::Expectations::ExpectationNotMetError, /No job of type 'my-task' was activated/)
      end
    end
  end

  describe "chaining with variables" do
    let(:variables_json) { '{"foo": "bar", "count": 42}' }

    it "passes when job has expected variables" do
      expect(helper).to have_activated("my-task").with_variables(foo: "bar")
    end

    it "fails when job lacks expected variables" do
      expect do
        expect(helper).to have_activated("my-task").with_variables(missing: "value")
      end.to raise_error(RSpec::Expectations::ExpectationNotMetError, /expected job variables to include/)
    end
  end

  describe "chaining with headers" do
    let(:custom_headers_json) { '{"workflow_version": "v2", "batch_id": "42"}' }

    it "passes when job has expected headers" do
      expect(helper).to have_activated("my-task").with_headers(workflow_version: "v2")
    end

    it "fails when job lacks expected headers" do
      expect do
        expect(helper).to have_activated("my-task").with_headers(missing: "value")
      end.to raise_error(RSpec::Expectations::ExpectationNotMetError, /expected job headers to include/)
    end
  end

  describe "chaining both variables and headers" do
    it "passes when job has both expected variables and headers" do
      expect(helper).to have_activated("my-task").
        with_variables(foo: "bar").
        with_headers(workflow_version: "v2")
    end

    it "fails when variables match but headers don't" do
      expect do
        expect(helper).to have_activated("my-task").
          with_variables(foo: "bar").
          with_headers(missing: "value")
      end.to raise_error(RSpec::Expectations::ExpectationNotMetError, /expected job headers to include/)
    end

    it "fails when headers match but variables don't" do
      expect do
        expect(helper).to have_activated("my-task").
          with_variables(missing: "value").
          with_headers(workflow_version: "v2")
      end.to raise_error(RSpec::Expectations::ExpectationNotMetError, /expected job variables to include/)
    end
  end
end
