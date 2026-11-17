# frozen_string_literal: true

require "busybee/testing"

RSpec.describe "an around-hook calling its continuation more than once" do # rubocop:disable RSpec/DescribeClass
  let(:performs) { [] }
  let(:after_performs) { [] }
  let(:outcomes) { [] }

  let(:worker) do
    performs_ref = performs
    Class.new(Busybee::Worker) do
      job_type "repeated"
      strict_outputs false

      define_method(:perform) do
        performs_ref << object_id
        raise ArgumentError, "perform boom #{performs_ref.size}" if job.variables["mode"] == "raise"

        { total: performs_ref.size }
      end
    end
  end

  let(:repeat_warning) do
    /\AWARN \[busybee\] Ignoring repeated continuation call from an around-hook \(at .+_spec\.rb:\d+\)/
  end

  around { |example| isolate_busybee_hooks { example.run } }

  before { Busybee.after_perform { |job| after_performs << job.status } }

  # `count` hooks of `type`, outermost first; the one at `repeater` calls its
  # continuation `calls` times and records each outcome.
  def register_hooks(type, count:, repeater:, calls: 2)
    count.times do |index|
      Busybee.public_send(type) do |_carrier, continuation|
        next continuation.call unless index == repeater

        calls.times { outcomes << outcome_of { continuation.call } }
      end
    end
  end

  def outcome_of
    [:returned, yield]
  rescue StandardError => e
    [:raised, e]
  end

  def run_job(**variables)
    execute_worker(worker, variables: variables)
  end

  %i[around_perform around_job_execution].each do |type|
    context "with #{type}" do
      [[2, 0, "the outer of two"], [2, 1, "the inner of two"],
       [3, 1, "the middle of three"]].each do |count, repeater, label|
        context "when #{label} hooks repeats after a successful descent" do
          it "runs perform, after_perform and the completion once" do
            register_hooks(type, count: count, repeater: repeater)

            job = run_job
            expect(performs.size).to eq(1)
            expect(after_performs).to eq([:complete])
            expect(job.client.received(:complete_job).size).to eq(1)
          end

          it "returns the first call's value from the repeat" do
            register_hooks(type, count: count, repeater: repeater, calls: 3)

            job = run_job
            expect(outcomes).to eq([[:returned, { "total" => 1 }]] * 3)
            expect(outcomes.map { |(_, value)| value }).to all(be(job.result))
          end

          it "warns on every repeat, naming the hook" do
            register_hooks(type, count: count, repeater: repeater, calls: 3)

            lines = capture_busybee_log { run_job }
            expect(lines.grep(/repeated continuation/)).to match([repeat_warning, repeat_warning])
          end
        end
      end

      it "stops the hooks below the repeating one from firing twice" do
        inner_entries = 0
        register_hooks(type, count: 1, repeater: 0)
        Busybee.public_send(type) do |_job, perform|
          inner_entries += 1
          perform.call
        end

        run_job
        expect(inner_entries).to eq(1)
      end
    end
  end

  context "with around_perform rescuing perform's error and calling perform again" do
    before do
      Busybee.around_perform do |_job, perform|
        perform.call
      rescue ArgumentError
        perform.call
      end
    end

    it "does not run perform again" do
      run_job(mode: "raise")
      expect(performs.size).to eq(1)
    end

    it "fails the job with perform's own error, as Zeebe's retries expect" do
      job = run_job(mode: "raise")
      expect(job).to be_failed
      expect(job.error.message).to eq("perform boom 1")
      expect(job.client.received(:fail_job).size).to eq(1)
      expect(job.client.received(:complete_job)).to be_empty
    end

    it "warns with the error the repeat re-raises" do
      lines = capture_busybee_log { run_job(mode: "raise") }
      expect(lines.grep(/repeated continuation/)).to match(
        [/#{repeat_warning.source} \(ArgumentError: perform boom 1\)\z/]
      )
    end
  end

  it "re-raises the very error the first around_perform call raised" do
    register_hooks(:around_perform, count: 2, repeater: 1)

    run_job(mode: "raise")
    expect(outcomes.map(&:first)).to eq(%i[raised raised])
    expect(outcomes.last.last).to be(outcomes.first.last)
  end

  context "with around_job_execution after the automatic completion failed on the wire" do
    let(:client) do
      Busybee::Testing::Client.new.on(:complete_job) { raise GRPC::Unavailable, "broker blinked" }
    end

    it "does not execute the job again" do
      register_hooks(:around_job_execution, count: 2, repeater: 1)

      execute_worker(worker, job: build_test_job(type: "repeated", client: client))
      expect(performs.size).to eq(1)
      expect(after_performs.size).to eq(1)
      expect(client.received(:complete_job).size).to eq(1)
    end
  end

  context "with around_job_execution rescuing a shutdown and calling perform again" do
    before { worker.shutdown_on ArgumentError }

    it "re-raises the shutdown instead of swallowing it" do
      first = nil
      Busybee.around_job_execution do |_job, perform|
        perform.call
      rescue Busybee::Worker::Shutdown => e
        first = e
        perform.call
      end

      lines = capture_busybee_log do
        expect { run_job(mode: "raise") }.to raise_error(Busybee::Worker::Shutdown) { |e| expect(e).to be(first) }
      end
      expect(performs.size).to eq(1)
      expect(lines.grep(/repeated continuation/)).to match(
        [/#{repeat_warning.source} \(Busybee::Worker::Shutdown: .*\)\z/]
      )
    end
  end

  context "with around_perform rescuing an error outside StandardError and calling perform again" do
    let(:unimplemented_worker) do
      Class.new(Busybee::Worker) do
        job_type "repeated"
        strict_outputs false
      end
    end

    it "re-raises that error rather than letting the job complete" do
      first = nil
      Busybee.around_perform do |_job, perform|
        perform.call
      rescue Exception => e # rubocop:disable Lint/RescueException
        first = e
        perform.call
      end
      job = build_test_job(type: "repeated")

      expect { execute_worker(unimplemented_worker, job: job) }.to raise_error(NotImplementedError) { |e|
        expect(e).to be(first)
      }
      expect(job).not_to be_completed
      expect(job.client.received(:complete_job)).to be_empty
    end
  end

  describe "around_call" do
    let(:client) { Busybee::Testing::Client.new }
    let(:resolutions) { [] }

    before { Busybee.after_call { |call| resolutions << [call.status, call.attempts] } }

    after do
      Busybee.grpc_retry_enabled = nil
      Busybee.grpc_retry_delay = nil
    end

    [[2, 0, "the outer of two"], [2, 1, "the inner of two"]].each do |count, repeater, label|
      it "does not re-send the request when #{label} hooks repeats" do
        register_hooks(:around_call, count: count, repeater: repeater)

        client.complete_job(5)
        expect(client.received(:complete_job).size).to eq(1)
        expect(resolutions).to eq([[:succeeded, 1]])
      end
    end

    it "warns on the repeat, naming the hook" do
      register_hooks(:around_call, count: 1, repeater: 0)

      lines = capture_busybee_log { client.complete_job(5) }
      expect(lines.grep(/repeated continuation/)).to match([repeat_warning])
    end

    context "when the attempt errored" do
      before do
        sends = 0
        client.on(:complete_job) do
          sends += 1
          raise GRPC::Unavailable, "broker blinked" if sends == 1

          Busybee::GRPC::CompleteJobResponse.new
        end
        register_hooks(:around_call, count: 2, repeater: 1)
      end

      it "leaves the call errored, sent once, with retries off" do
        Busybee.grpc_retry_enabled = false

        expect { client.complete_job(5) }.to raise_error(Busybee::GRPC::Error, /broker blinked/)
        expect(client.received(:complete_job).size).to eq(1)
        expect(resolutions).to eq([[:errored, 1]])
      end

      it "leaves the retry to busybee's own next attempt, with retries on" do
        Busybee.grpc_retry_enabled = true
        Busybee.grpc_retry_delay = 0

        client.complete_job(5)
        expect(client.received(:complete_job).size).to eq(2)
        expect(resolutions).to eq([[:succeeded, 2]])
      end
    end
  end
end
