# frozen_string_literal: true

require "concurrent"

# End-to-end coverage for the call hooks firing against a live Zeebe cluster.
# A real Client operation drives the two-level seam — before_call / after_call
# bracket the logical call, around_call wraps each attempt — and each hook
# receives a real Client::Call carrying the rpc, resolved status, grpc_status,
# attempt count, and total duration. The unit specs drive this with a stub stub;
# here the gRPC round-trip is real.
RSpec.describe "Call hooks", :integration do
  include Busybee::Testing::Helpers

  let(:job_bpmn_path) { File.expand_path("../../fixtures/job_process.bpmn", __dir__) }
  let(:client) { local_busybee_client }

  # Each hook records an immutable snapshot — the Call mutates as it resolves
  # (status :pending -> :succeeded/:errored), so retaining the live reference
  # would observe only its final state.
  let(:fired) { Concurrent::Hash.new { |hash, key| hash[key] = Concurrent::Array.new } }

  around do |example|
    original = Busybee.credential_type
    Busybee.credential_type = :insecure
    example.run
    Busybee.credential_type = original
  end

  before do
    Busybee::Hooks.reset!
    Busybee.before_call { |call| fired[:before] << snapshot(call) }
    Busybee.after_call  { |call| fired[:after]  << snapshot(call) }
    Busybee.around_call do |call, continue|
      fired[:around] << snapshot(call)
      continue.call
    end
  end

  after { Busybee::Hooks.reset! }

  it "brackets a successful op with before/around/after_call" do
    client.deploy_process(job_bpmn_path)

    aggregate_failures do
      expect(fired[:before].size).to eq(1)
      expect(fired[:after].size).to eq(1)
      expect(fired[:around].size).to be >= 1
      expect(fired[:before].first[:rpc]).to eq(:deploy_resource)
      expect(fired[:before].first[:status]).to eq(:pending) # not resolved at before_call
    end
  end

  it "presents a resolved, succeeded Call at after_call" do
    client.deploy_process(job_bpmn_path)

    after = fired[:after].first
    aggregate_failures do
      expect(after[:rpc]).to eq(:deploy_resource)
      expect(after[:status]).to eq(:succeeded)
      expect(after[:grpc_status]).to eq(:ok)
      expect(after[:attempts]).to eq(1) # no retry on success
      expect(after[:total_ms]).to be_a(Float)
      expect(after[:error_class]).to be_nil
    end
  end

  it "presents an errored Call at after_call when the op fails" do
    expect { client.cancel_instance(999_999_999) }.to raise_error(Busybee::GRPC::Error)

    after = fired[:after].last
    aggregate_failures do
      expect(after[:rpc]).to eq(:cancel_process_instance)
      expect(after[:status]).to eq(:errored)
      expect(after[:grpc_status]).to be_a(Symbol) # a real gRPC failure code
      expect(after[:error_class]).to eq(Busybee::GRPC::Error) # the Class, matching worker_class
    end
  end

  private

  def snapshot(call)
    {
      rpc: call.rpc,
      status: call.status,
      grpc_status: call.grpc_status,
      attempts: call.attempts,
      total_ms: call.total_ms,
      error_class: call.error_class
    }
  end
end
