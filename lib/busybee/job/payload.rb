# frozen_string_literal: true

require "busybee/error"
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
      alias job_type type

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

      # Low-cardinality projection of the immutable payload fields (suitable for
      # metric labels). Omits retries/deadline: those carry Job-level overrides
      # (update_retries / update_timeout), so Job contributes their effective
      # values to the aggregate projection.
      def context_tags
        {
          job_type: type,
          bpmn_process_id: bpmn_process_id,
          element_id: element_id
        }.compact
      end

      # High-cardinality projection: context_tags plus the job identifiers.
      def logging_context
        context_tags.merge(
          job_key: key,
          process_instance_key: process_instance_key
        ).compact
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
