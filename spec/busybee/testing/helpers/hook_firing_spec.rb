# frozen_string_literal: true

require "busybee/testing"

RSpec.describe Busybee::Testing::Helpers::HookFiring do
  let(:worker_class) do
    Class.new(Busybee::Worker) do
      job_type "fired"

      def perform = nil
    end
  end
  let(:seen) { [] }

  around do |example|
    with_isolated_hooks do
      example.run
    end
  end

  def failed_job(**) = build_test_job(type: "fired", status: :failed, **)

  describe "#fire_hooks" do
    it "runs each registered hook of the moment whose filters accept the carrier, against it" do
      Busybee::Hooks.after_perform(status: :failed) { |job| seen << [:failed, job] }
      Busybee::Hooks.after_perform(job_type: "fired") { |job| seen << [:typed, job] }
      job = failed_job

      fire_hooks(:after_perform, job)

      expect(seen).to eq([[:failed, job], [:typed, job]])
    end

    it "leaves a hook whose filters don't accept the carrier unrun, so wiring shows as effect" do
      Busybee::Hooks.after_perform(job_type: "some_other_type") { |job| seen << job }

      fire_hooks(:after_perform, failed_job)

      expect(seen).to be_empty
    end

    it "fires only the named moment" do
      Busybee::Hooks.on_job_executed { |job| seen << job }

      fire_hooks(:after_perform, failed_job)

      expect(seen).to be_empty
    end

    it "returns the carrier it was given" do
      job = failed_job

      expect(fire_hooks(:after_perform, job)).to be(job)
    end

    it "raises what a hook body raises, rather than logging it" do
      Busybee::Hooks.on_job_executed { |_job| raise ArgumentError, "hook bug" }

      expect { fire_hooks(:on_job_executed, failed_job) }.to raise_error(ArgumentError, "hook bug")
    end

    describe "around a continuation" do
      before do
        Busybee::Hooks.around_perform do |_job, perform|
          seen << :enter
          perform.call
          seen << :exit
        end
      end

      it "runs the block as the continuation, inside every matching hook" do
        fire_hooks(:around_perform, build_test_job(type: "fired")) { seen << :inner }

        expect(seen).to eq(%i[enter inner exit])
      end

      it "still descends with no block" do
        fire_hooks(:around_perform, build_test_job(type: "fired"))

        expect(seen).to eq(%i[enter exit])
      end
    end

    describe "worker moments" do
      before { Busybee::Hooks.on_worker_shutdown { |status| seen << status } }

      it "takes a built Worker::Status" do
        status = build_test_worker_status(worker_class: worker_class)

        fire_hooks(:on_worker_shutdown, status)

        expect(seen).to eq([status])
      end

      it "takes a test worker, firing with a real snapshot of it" do
        worker = start_test_worker(worker_class)

        expect(fire_hooks(:on_worker_shutdown, worker)).to be(worker)
        expect(seen).to contain_exactly(an_instance_of(Busybee::Worker::Status).
                                          and(have_attributes(worker_class: worker_class)))
      end
    end

    it "takes a Call for a call moment" do
      Busybee::Hooks.after_call { |call| seen << call }
      call = build_test_call(:complete_job)

      fire_hooks(:after_call, call)

      expect(seen).to eq([call])
    end

    it "refuses a carrier of the wrong kind for the moment, naming the right one" do
      expect { fire_hooks(:after_call, failed_job) }.to raise_error(ArgumentError, /after_call.*Busybee::Client::Call/)
      expect { fire_hooks(:on_worker_started, failed_job) }.to raise_error(ArgumentError, /Worker::Status/)
    end

    it "refuses an unknown moment" do
      expect { fire_hooks(:after_everything, failed_job) }.to raise_error(ArgumentError, /after_everything/)
    end

    describe "under without_hooks" do
      before { Busybee::Hooks.after_call { |call| seen << call } }

      it "raises rather than firing nothing, naming the suppression" do
        without_hooks(:call) do
          expect { fire_hooks(:after_call, build_test_call(:complete_job)) }.
            to raise_error(ArgumentError, /after_call.*without_hooks/m)
        end
      end

      it "runs the hooks registered inside the suppression" do
        without_hooks(:call) do
          Busybee::Hooks.after_call { |call| seen << [:inside, call] }
          fire_hooks(:after_call, build_test_call(:complete_job))
        end

        expect(seen.map(&:first)).to eq([:inside])
      end
    end

    describe "correlation" do
      let(:client) { build_test_client }
      let(:status) { build_test_worker_status(worker_class: worker_class) }
      let(:job) { build_test_job(type: "fired", client: client, worker_status: status) }
      let(:calls) { [] }

      before do
        Busybee::Hooks.after_call { |call| calls << call }
        publish = ->(carrier) { carrier.client.publish_message("probe", correlation_key: "k") }
        Busybee::Hooks.before_perform(&publish)
        Busybee::Hooks.on_job_activated(&publish)
      end

      it "attributes a call made from a perform hook to the job, as perform does" do
        fire_hooks(:before_perform, job)

        expect(calls).to contain_exactly(have_attributes(rpc: :publish_message, job: job, worker_status: status))
      end

      it "attributes a call made from a job-lifecycle hook to the job's worker status" do
        fire_hooks(:on_job_activated, job)

        expect(calls).to contain_exactly(have_attributes(job: nil, worker_status: status))
      end
    end

    it "can fire every one of the 14 moments with a buildable carrier" do
      carriers = {
        job: build_test_job(type: "fired"),
        worker: build_test_worker_status(worker_class: worker_class),
        call: build_test_call(:complete_job)
      }
      Busybee::Hooks::HOOK_TYPES.each do |type|
        Busybee::Hooks.register(type, ->(*) { seen << type })
      end

      Busybee::Hooks::HOOK_NOUN.each { |type, noun| fire_hooks(type, carriers.fetch(noun)) }

      expect(seen).to eq(Busybee::Hooks::HOOK_TYPES)
    end
  end
end
