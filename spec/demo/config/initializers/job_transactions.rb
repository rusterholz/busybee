# frozen_string_literal: true

# Demonstrates busybee's around_job hook: wrap a job's perform in a database
# transaction so all of its writes commit atomically (and roll back together if
# perform raises). Registered for a set of job types via the job_type filter's
# array (match-any) support — not globally, because a blanket wrapper is wrong
# for some workers:
#
#   - complete_driver_delivery publishes a Zeebe message mid-perform; a database
#     transaction can't roll an external message back.
#   - The Sim workers (simulate_pick_and_pack, simulate_delivery_run) are async —
#     perform returns immediately and the real work runs in a background Future —
#     so a transaction around perform is a no-op.
#
# The job types listed here are synchronous and write only to the database, so
# the hook owns their atomicity and they no longer open transactions themselves.
Busybee.around_job(
  job_type: %w[update_order_status create_shipment update_shipment_status assign_driver]
) do |_job, perform|
  ActiveRecord::Base.transaction { perform.call }
end
