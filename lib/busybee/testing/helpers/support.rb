# frozen_string_literal: true

require "grpc"
require "securerandom"

require "busybee/credentials"
require "busybee/durations"
require "busybee/grpc"
require "busybee/testing/timings"

module Busybee
  module Testing
    module Helpers
      # These methods are available *on Helpers,* as module-level methods, which keeps them
      # isolated from the test context of the public helper methods which consume them.
      module Support
        def unique_process_id
          "test-process-#{SecureRandom.hex(6)}"
        end

        def extract_process_id(bpmn_content)
          match = bpmn_content.match(/<bpmn:process id="([^"]+)"/)
          match ? match[1] : nil
        end

        def bpmn_with_unique_id(bpmn_path, process_id)
          bpmn_content = File.read(bpmn_path)
          bpmn_content.
            gsub(/(<bpmn:process id=")[^"]+/, "\\1#{process_id}").
            # Possessive quantifiers (++, *+) prevent polynomial backtracking
            gsub(/(<bpmndi:BPMNPlane\s++[^>]*+bpmnElement=")[^"]++/, "\\1#{process_id}")
        end

        # A failure to cancel fails the example, unless the example already failed:
        # then its own error stands and the instance left running is only warned of.
        def cancel_process_instance(key, after_failure: false)
          request = Busybee::GRPC::CancelProcessInstanceRequest.new(
            processInstanceKey: key
          )
          grpc_client.cancel_process_instance(request)
          true
        rescue ::GRPC::NotFound
          # Process already completed, ignore
          false
        rescue StandardError => e
          raise unless after_failure

          warn "[busybee] Failed to cancel process instance #{key} after the example failed; " \
               "it is still running (#{e.class}: #{e.message})"
          false
        end

        def activate_jobs_raw(type, max_jobs:, timeout: nil)
          worker = "#{type}-#{SecureRandom.hex(4)}"

          request_timeout = timeout || Busybee::Testing::ACTIVATE_JOB_TIMEOUT_MS
          request_timeout_ms = Busybee::Durations.milliseconds_from(request_timeout)

          request = Busybee::GRPC::ActivateJobsRequest.new(
            type: type,
            worker: worker,
            timeout: Busybee::Testing::ACTIVATE_JOB_LOCK_MS,
            maxJobsToActivate: max_jobs,
            requestTimeout: request_timeout_ms
          )

          jobs = []
          grpc_client.activate_jobs(request).each do |response|
            jobs.concat(response.jobs.to_a)
          end
          jobs
        end

        # Activates until a job of the test's own arrives or the wait runs out,
        # handing back each foreign one as it comes.
        #
        # @param foreign [ForeignJobs] which jobs to refuse
        # @return [Array(Array, Array)] the jobs kept, and those handed back (one per job key)
        def activate_own_jobs(type, max_jobs:, foreign:, timeout: nil)
          wait = timeout || Busybee::Testing::ACTIVATE_JOB_TIMEOUT_MS
          deadline = deadline_after(wait)
          refused = {}
          loop do
            others, own = activate_jobs_raw(type, max_jobs: max_jobs, timeout: wait).partition { foreign.foreign?(_1) }
            hand_back_all(others, foreign, refused)
            wait = ms_left(deadline)
            return [own, refused.values] if own.any? || others.empty? || wait < 1
          end
        end

        def deadline_after(wait) = monotonic_now + (Busybee::Durations.milliseconds_from(wait) / 1000.0)
        def ms_left(deadline) = ((deadline - monotonic_now) * 1000).floor

        # Every job goes back before the first hand-back error is raised.
        #
        # @param refused [Hash] the activation's refused jobs by key, added to here
        def hand_back_all(jobs, foreign, refused)
          errors = jobs.filter_map do |job|
            refused[job.key] = job
            hand_back(job, foreign, backoff: foreign_job_backoff(refused.size))
            nil
          rescue StandardError => e
            e
          end
          raise errors.first if errors.any?
        end

        # Each distinct job an activation refuses sits out longer than the one
        # before, so the oldest-first queue can't hand the same few back before
        # the rest have been seen.
        def foreign_job_backoff(refused_so_far)
          [Busybee::Testing::FOREIGN_JOB_BACKOFF_MS * refused_so_far, Busybee::Testing::FOREIGN_JOB_MAX_BACKOFF_MS].min
        end

        # Back to the engine unworked: retries untouched, and out of reach for
        # the backoff so the next activation can find another job.
        def hand_back(job, foreign, backoff:)
          grpc_client.fail_job(
            Busybee::GRPC::FailJobRequest.new(
              jobKey: job.key, retries: job.retries, errorMessage: foreign.hand_back_message(job),
              retryBackOff: backoff
            )
          )
          job
        rescue ::GRPC::NotFound
          job # its instance ended meanwhile
        end

        def monotonic_now = Process.clock_gettime(Process::CLOCK_MONOTONIC)

        # This is the central grpc_client implementation (the one you should usually mock in a test).
        # The actual public helper instance method delegates to this. It uses Busybee.credential_type
        # if set, and attempts to autodetect from env vars otherwise.
        def grpc_client
          Busybee::Credentials.build.grpc_stub
        end
      end
    end
  end
end
