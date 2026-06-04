# frozen_string_literal: true

require "busybee/serialization"

module Busybee
  class Job
    # Read-only view of a Job's underlying GRPC ActivatedJob protobuf.
    # Pulls every protobuf accessor (key, type, bpmn_process_id, etc.) and
    # the JSON parsing of variables / customHeaders into one PORO, leaving
    # Job to focus on lifecycle state (activation, resolution, etc.).
    #
    # Differs from the other Job POROs: no harvest!, no set_context routing,
    # no fire-once guard. The protobuf is set once at construction and the
    # readers are immutable views. Override layers for retries (via
    # update_retries) and deadline (via update_timeout) live on Job, not
    # here — Payload only knows the protobuf truth.
    class Payload
      def initialize(raw_job)
        @raw_job = raw_job
      end

      def key
        @raw_job.key
      end

      def type
        @raw_job.type
      end

      def process_instance_key
        @raw_job.processInstanceKey
      end

      def bpmn_process_id
        @raw_job.bpmnProcessId
      end

      def element_id
        @raw_job.elementId
      end

      def retries
        @raw_job.retries
      end

      def deadline
        @deadline ||= Time.at(@raw_job.deadline / 1000.0).utc.freeze
      end

      def variables
        @variables ||= parse_and_freeze_hash(@raw_job.variables, "variables")
      end

      def headers
        @headers ||= parse_and_freeze_hash(@raw_job.customHeaders, "headers")
      end

      private

      def parse_and_freeze_hash(json_string, attribute_name)
        Busybee::Serialization.from_json(json_string)
      rescue Busybee::InvalidJobJson => e
        message = "Failed to parse job #{attribute_name}: #{e.cause.message}"
        raise Busybee::InvalidJobJson, message, e.backtrace, cause: e.cause
      end
    end
  end
end
