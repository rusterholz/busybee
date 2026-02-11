# frozen_string_literal: true

require "active_support/core_ext/module/delegation"
require "busybee/worker/configuration"
require "busybee/worker/dsl"

module Busybee
  # Base class for defining job workers.
  #
  # Subclass and implement `perform` to handle jobs from the workflow engine.
  # Runners call `perform_job(job)` as the entry point (internal use only).
  #
  # @example Minimal worker
  #   class ProcessOrderWorker < Busybee::Worker
  #     job_type "process-order"
  #
  #     def perform
  #       order = Order.find(variables[:order_id])
  #       order.process!
  #       complete!(status: order.status)
  #     end
  #   end
  #
  class Worker
    extend DSL

    attr_reader :job

    delegate :variables, :headers, :complete!, :fail!, :throw_bpmn_error!,
             :update_retries, :update_timeout, to: :job

    def initialize(job)
      @job = job
    end

    def perform
      raise NotImplementedError,
            "#{self.class.name} must implement `perform`"
    end

    # Entry point called by Runners. Creates a new worker instance and calls perform.
    # Mission 9: will add input validation, autocomplete, autofail, unhealthy_on wrapping.
    def self.perform_job(job)
      instance = new(job)
      instance.perform
    end
  end
end
