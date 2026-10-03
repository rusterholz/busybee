# frozen_string_literal: true

# Drives real calls over a real wire, because the claim is about what does and
# does not reach the gateway when a hook calls back into the client.
RSpec.describe "making a client call from inside a hook", :gateway do # rubocop:disable RSpec/DescribeClass
  let(:client) { gateway.client }

  before { gateway.on(:complete_job) { Busybee::GRPC::CompleteJobResponse.new } }

  around { |example| with_isolated_hooks { example.run } }

  describe "from a call hook — refused" do
    # Left unguarded this recurses through run_hooked → with_hooks → the same
    # hook, unbounded, and lands on SystemStackError — which is not a
    # StandardError and so pierces every safe layer on its way out.
    it "refuses a call made from after_call instead of recursing into it" do
      attempted = nil
      Busybee.after_call(rpc: :complete_job) do
        attempted = begin
          client.complete_job(2)
          :reached_the_wire
        rescue Busybee::ReentrantCall => e
          e
        end
      end

      client.complete_job(1)

      aggregate_failures do
        expect(attempted).to be_a(Busybee::ReentrantCall)
        expect(gateway.received(:complete_job).length).to eq(1)
      end
    end

    it "refuses a call made from around_call" do
      attempted = nil
      Busybee.around_call(rpc: :complete_job) do |_call, continue|
        attempted = begin
          client.complete_job(2)
          :reached_the_wire
        rescue Busybee::ReentrantCall => e
          e
        end
        continue.call
      end

      client.complete_job(1)

      expect(attempted).to be_a(Busybee::ReentrantCall)
    end

    # before_call propagates by design — it is the gating hook — so an adopter
    # who calls from there loses the call they were gating.
    it "aborts the outer call when before_call makes one" do
      Busybee.before_call(rpc: :complete_job) { client.complete_job(2) }

      expect { client.complete_job(1) }.to raise_error(Busybee::ReentrantCall)
      expect(gateway.received(:complete_job)).to be_empty
    end

    it "names the rpc that was refused, so the offending hook is findable" do
      attempted = nil
      Busybee.after_call(rpc: :complete_job) do
        attempted = begin
          client.complete_job(2)
        rescue Busybee::ReentrantCall => e
          e
        end
      end

      client.complete_job(1)

      expect(attempted.message).to include("complete_job")
    end
  end

  describe "from a job hook — allowed" do
    it "lets a job hook make a client call, because nothing recurses there" do
      job = build_test_job(type: "reentrancy_worker")
      Busybee.on_job_activated { client.complete_job(7) }

      Busybee::Hooks.run(:on_job_activated, job)

      expect(gateway.received(:complete_job).map(&:jobKey)).to eq([7])
    end
  end

  describe "the latch does not leak" do
    it "leaves the thread able to make the next call" do
      Busybee.after_call(rpc: :complete_job) { nil }

      client.complete_job(1)
      client.complete_job(2)

      expect(gateway.received(:complete_job).map(&:jobKey)).to eq([1, 2])
    end

    it "leaves the thread able to call again after a call raised" do
      gateway.on(:complete_job) { raise GRPC::NotFound, "no such job" }
      begin
        client.complete_job(1)
      rescue Busybee::GRPC::Error # rubocop:disable Lint/SuppressedException
      end
      gateway.on(:complete_job) { Busybee::GRPC::CompleteJobResponse.new }

      expect { client.complete_job(2) }.not_to raise_error
    end
  end
end
