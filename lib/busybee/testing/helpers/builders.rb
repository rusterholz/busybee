# frozen_string_literal: true

require "busybee/client/call"
require "busybee/durations"
require "busybee/testing/client"
require "busybee/testing/hook_registry"
require "busybee/testing/runner"
require "busybee/worker/status"
require "busybee/worker/timestamps"

module Busybee
  module Testing
    module Helpers
      # Builders for the carriers a spec needs as fixtures — the Job,
      # Worker::Status and Call that hooks receive, plus the Client they resolve
      # through. They build what production builds, because a hook reads its
      # carrier's projections: a hand-rolled double freezes the spec's belief
      # about those into its assertions, and renaming a key then breaks the hook
      # while the spec stays green.
      #
      # @example A status a worker hook would receive
      #   status = build_test_worker_status(worker_class: MyWorker, total_job_count: 7)
      #   MyMonitor.record(status)
      module Builders
        # A Worker::Status as the runner snapshots it. Note what it refuses that a
        # double allowed: job_type is *derived* from worker_class, so the two can't
        # disagree; error_message comes from a real exception; and worker_name is
        # no field at all — set the gem config if a spec needs a particular one.
        #
        # @param worker_class [Class<Busybee::Worker>] the worker this run is of
        # @param worker_mode [Symbol] :polling, :streaming or :hybrid
        # @param moments [Array<Symbol>] lifecycle moments to stamp, in order
        # @param attrs [Hash] counters, gauges, reason:, error: — see Worker::Status
        # @return [Busybee::Worker::Status]
        def build_test_worker_status(worker_class:, worker_mode: :polling, moments: [:started_at], **attrs)
          timestamps = Busybee::Worker::Timestamps.new
          moments.each { |moment| timestamps.stamp!(moment) }
          Busybee::Worker::Status.new(
            worker_class: worker_class, worker_mode: worker_mode, timestamps: timestamps, **attrs
          )
        end

        # A real client over an in-process transport; see Testing::Client.
        #
        # @return [Busybee::Testing::Client]
        def build_test_client(...) = Busybee::Testing::Client.new(...)

        # A worker for this worker class, built but not started, so nothing fires
        # yet; see Testing::Runner.
        #
        # @param worker_class [Class<Busybee::Worker>]
        # @param client [Busybee::Client] defaults to a fresh {build_test_client}
        # @return [Busybee::Testing::Runner]
        def build_test_worker(worker_class, client: nil)
          Busybee::Testing::Runner.new(worker_class, client: client || build_test_client)
        end

        # {build_test_worker}, started: on_worker_started has fired.
        #
        # @return [Busybee::Testing::Runner]
        def start_test_worker(...) = build_test_worker(...).start

        # A Job as the runner hands one to a hook: a real ActivatedJob proto —
        # which validates its own field types, so a key the wire could not carry
        # fails here rather than in a spec's imagination — wrapped and given its
        # activation context by the same route Runner#activate_job uses.
        #
        # @param type [String] job type
        # @param variables [Hash] process variables
        # @param headers [Hash] custom headers
        # @param key [Integer] job key; defaults to a random one. Pass it when a
        #   spec correlates the same job across assertions.
        # @param client [Busybee::Client] defaults to a fresh {build_test_client},
        #   so resolving the job runs the genuine call seam and fires call hooks
        # @param worker_class [Class<Busybee::Worker>] what a job-noun filter matches on
        # @param worker_status [Busybee::Worker::Status] the runner snapshot the job carries
        # @param source [Symbol, nil] :poll or :stream; nil, the default, is no transport
        # @param buffered [Boolean] whether this job came through a runner buffer
        # @param activated [Boolean] stamp activated_at, as activation does
        # @param status [Symbol, nil] :complete, :failed or :error to hand back a
        #   job that already resolved — reached by driving the real resolution
        # @return [Busybee::Job]
        def build_test_job(type: "test", key: nil, variables: {}, headers: {}, # rubocop:disable Metrics/ParameterLists
                           bpmn_process_id: "test-process", element_id: "test-element",
                           retries: 3, worker: nil, tenant_id: nil, client: nil,
                           worker_class: nil, worker_status: nil, source: nil,
                           buffered: false, activated: true, status: nil)
          raw_job = build_test_raw_job(type: type, key: key, variables: variables, headers: headers,
                                       bpmn_process_id: bpmn_process_id, element_id: element_id,
                                       retries: retries, worker: worker, tenant_id: tenant_id)
          job = Busybee::Job.new(raw_job, client: client || build_test_client)
          HookRegistry.with_only do # a fixture must not fire the hooks under test
            job.set_context(worker_class: worker_class, worker_status: worker_status,
                            source: source, buffered: buffered)
            job.timestamps.stamp!(:activated_at) if activated
            resolve_test_job(job, status) if status
          end
          job
        end

        # The bare proto, for the places that need one before a Job exists — a
        # stub's ActivateJobsResponse, say, which cannot carry a wrapped Job.
        #
        # @return [Busybee::GRPC::ActivatedJob]
        def build_test_raw_job(type: "test", key: nil, variables: {}, headers: {}, # rubocop:disable Metrics/ParameterLists
                               bpmn_process_id: "test-process", element_id: "test-element",
                               retries: 3, worker: nil, tenant_id: nil)
          Busybee::GRPC::ActivatedJob.new(
            key: key || rand(100_000..999_999),
            type: type.to_s,
            processInstanceKey: rand(100_000..999_999),
            bpmnProcessId: bpmn_process_id.to_s,
            elementId: element_id.to_s,
            retries: retries,
            worker: (worker || Busybee.worker_name).to_s,
            deadline: (Time.now.to_i + 300) * 1000,
            variables: Busybee::Serialization.to_json(variables),
            customHeaders: Busybee::Serialization.to_json(headers),
            tenantId: tenant_id.to_s
          )
        end

        # A Call as a call hook meets it, driven through the same underscore seam
        # the client drives — so logging_context and context_tags *compute*. Those
        # two projections are the contract, and a spec that authors them by hand
        # can never fail when the contract moves.
        #
        # @param rpc [Symbol] the underscored RPC name
        # @param request [Object, nil] the request proto this call carries
        # @param job [Busybee::Job, nil] correlates the call — note a job's own
        #   worker_status wins over any passed separately, as in production
        # @param worker_status [Busybee::Worker::Status, nil] correlates a job-less
        #   fetch call
        # @param status [Symbol] :succeeded or :errored
        # @param result [Object, nil] what the wire handed back
        # @param error [Exception, nil] what the wire raised; defaults to
        #   GRPC::Unavailable when status is :errored
        # @param attempted [Boolean] false leaves it pending, with nothing observed
        # @param network [Integer, ActiveSupport::Duration] how long to spend "on
        #   the wire" (a bare number is milliseconds), so the observed network_ms
        #   is a real measurement rather than zero
        # @return [Busybee::Client::Call]
        def build_test_call(rpc, request: nil, job: nil, worker_status: nil, # rubocop:disable Metrics/ParameterLists
                            status: :succeeded, result: nil, error: nil,
                            attempted: true, network: 1)
          correlating(job, worker_status) do
            call = Busybee::Client::Call.new(rpc, request)
            next call unless attempted

            attempt_test_call(call, status: status, result: result, error: error, network: network)
            call._resolve(status: status)
            call
          end
        end

        private

        # The chain re-raises past itself — the client's own rescue catches that;
        # swallow here so the builder hands back a settled carrier.
        def attempt_test_call(call, status:, result:, error:, network:)
          call.attempt do
            sleep Busybee::Durations.seconds_from(network)
            raise(error || ::GRPC::Unavailable.new("broker unreachable")) if status == :errored

            result
          end
        rescue Busybee::GRPC::Error, ::GRPC::BadStatus
          nil
        end

        def correlating(job, worker_status, &)
          return Busybee::Client::Call.with_job(job, &) if job
          return Busybee::Client::Call.with_worker_status(worker_status, &) if worker_status

          yield
        end

        # The real lifecycle method, not the axis: so the job carries what a
        # resolved one carries — timestamps, the outbound RPC, the retries decrement.
        def resolve_test_job(job, status)
          case status
          when :complete then job.complete!
          when :failed then job.fail!("test failure")
          when :error then job.throw_bpmn_error!(:test_error, "test error")
          else raise ArgumentError, "Unknown status: #{status.inspect}. Expected :complete, :failed or :error."
          end
        end
      end
    end
  end
end
