# frozen_string_literal: true

require "active_support"
require "active_support/duration"
require "json"
require "securerandom"
require "busybee/grpc"

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

        def cancel_process_instance(key)
          request = Busybee::GRPC::CancelProcessInstanceRequest.new(
            processInstanceKey: key
          )
          grpc_client.cancel_process_instance(request)
          true
        rescue ::GRPC::NotFound
          # Process already completed, ignore
          false
        end

        def activate_jobs_raw(type, max_jobs:, timeout: nil)
          worker = "#{type}-#{SecureRandom.hex(4)}"

          request_timeout = timeout || Busybee::Testing.activate_request_timeout
          request_timeout_ms = if request_timeout.is_a?(ActiveSupport::Duration)
                                 request_timeout.in_milliseconds.to_i
                               else
                                 request_timeout.to_i
                               end

          request = Busybee::GRPC::ActivateJobsRequest.new(
            type: type,
            worker: worker,
            timeout: 30_000,
            maxJobsToActivate: max_jobs,
            requestTimeout: request_timeout_ms
          )

          jobs = []
          grpc_client.activate_jobs(request).each do |response|
            jobs.concat(response.jobs.to_a)
          end
          jobs
        end

        # This is the central grpc_client implementation (the one you should usually mock in a test).
        # The actual public helper instance method delegates to this. It uses Busybee.credential_type
        # if set, and attempts to autodetect from env vars otherwise.
        def grpc_client
          require "busybee/credentials"
          Busybee::Credentials.build.grpc_stub
        end
      end
    end
  end
end
