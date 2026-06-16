# frozen_string_literal: true

# Demonstrates busybee's around_job hook: wrap a job's perform in a database
# transaction so all of its writes commit atomically (and roll back together if
# perform raises). Registered per worker via the worker_class filter — string
# values match by class name — rather than globally, because a blanket wrapper
# is wrong for some workers:
#
#   - Delivery::CompleteDriverDeliveryWorker publishes a Zeebe message mid-perform;
#     a database transaction can't roll an external message back.
#   - The Sim workers are async — perform returns immediately and the real work
#     runs in a background Future — so a transaction around perform is a no-op.
#
# The workers listed here are synchronous and write only to the database, so the
# hook owns their atomicity and they no longer open transactions themselves.
%w[
  Oms::UpdateOrderStatusWorker
  Logistics::CreateShipmentWorker
  Logistics::UpdateShipmentStatusWorker
  Delivery::AssignDriverWorker
].each do |worker_class|
  Busybee.around_job(worker_class: worker_class) do |_job, perform|
    ActiveRecord::Base.transaction { perform.call }
  end
end
