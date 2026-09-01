# frozen_string_literal: true

# Drives real client calls over a real wire, so "did the mutation actually reach
# the broker?" is answered by what the gateway received rather than by what the
# carrier reports about itself.
RSpec.describe "mutating a request on its way to the wire", :gateway do # rubocop:disable RSpec/DescribeClass
  let(:client) { gateway.client }

  after { Busybee::Hooks.reset! }

  describe "before_call" do
    before { gateway.on(:fail_job) { Busybee::GRPC::FailJobResponse.new } }

    it "sends what the hook left behind rather than what the caller built" do
      Busybee.before_call(rpc: :fail_job) do |call|
        call.request.errorMessage = "[redacted]"
        call.request.retries = 7
      end

      client.fail_job(99, "card 4111-1111-1111-1111 declined", retries: 2)

      sent = gateway.received(:fail_job).last
      expect(sent.errorMessage).to eq("[redacted]")
      expect(sent.retries).to eq(7)
    end

    # Both halves matter and neither implies the other: writable while the hook
    # holds it, and the very same object afterwards — a copy taken on the first
    # attempt would satisfy the first assertion while sending something else.
    it "is handed the request that goes on to be sent, while it is still writable" do
      seen = nil
      Busybee.before_call(rpc: :fail_job) { |call| seen = [call.request, call.request.frozen?] }

      client.fail_job(99, "boom")

      request, frozen_while_held = seen
      expect(frozen_while_held).to be(false)
      expect(request).to be_frozen
    end
  end

  describe "across a retry" do
    before do
      Busybee.grpc_retry_enabled = true
      Busybee.grpc_retry_delay = 0 # the retry's timing is not this file's claim
      sends = 0
      gateway.on(:fail_job) do
        sends += 1
        raise GRPC::Unavailable, "broker blinked" if sends == 1

        Busybee::GRPC::FailJobResponse.new
      end
    end

    after do
      Busybee.grpc_retry_enabled = nil
      Busybee.grpc_retry_delay = nil
    end

    it "carries a before_call mutation into the second attempt" do
      Busybee.before_call(rpc: :fail_job) { |call| call.request.errorMessage = "[redacted]" }

      client.fail_job(99, "card 4111-1111-1111-1111 declined")

      expect(gateway.received(:fail_job).map(&:errorMessage)).to eq(["[redacted]", "[redacted]"])
    end

    # Distinct values per attempt are what separate a reopened request from a
    # reused one: a copy that came back frozen, or a wire that kept sending the
    # first attempt's object, both report [1, 1] here.
    it "lets around_call rewrite the request on every attempt" do
      Busybee.around_call(rpc: :fail_job) do |call, continue|
        call.request.retries = call.attempts
        continue.call
      end

      client.fail_job(99, "boom")

      expect(gateway.received(:fail_job).map(&:retries)).to eq([1, 2])
    end

    it "seals each attempt's request before its own chain unwinds" do
      sealed = []
      Busybee.around_call(rpc: :fail_job) do |call, continue|
        continue.call
        sealed << call.request.frozen?
      end

      client.fail_job(99, "boom")

      expect(sealed).to eq([true, true])
    end

    it "hands after_call the request the final attempt actually sent" do
      Busybee.around_call(rpc: :fail_job) do |call, continue|
        call.request.retries = call.attempts
        continue.call
      end
      seen = nil
      Busybee.after_call(rpc: :fail_job) { |call| seen = call.request }

      client.fail_job(99, "boom")

      expect(seen).to be_frozen
      expect(seen.retries).to eq(gateway.received(:fail_job).last.retries)
    end
  end

  describe "once the request has been sent" do
    before { gateway.on(:complete_job) { Busybee::GRPC::CompleteJobResponse.new } }

    it "hands after_call a request nothing can still rewrite" do
      seen = nil
      Busybee.after_call(rpc: :complete_job) { |call| seen = call.request }

      client.complete_job(1, vars: { a: 1 })

      expect(seen).to be_frozen
      expect { seen.variables = "{}" }.to raise_error(FrozenError)
    end
  end
end
