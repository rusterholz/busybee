# Busybee Feedback from Demo App Development

Aha moments and feature ideas discovered while building the demo app. Each item is something a future session can pick up as a busybee enhancement.

---

## Worker-level transaction hooks

**Discovered during:** Phase 2 (model/callback design review)

**Context:** The `CreateShipmentWorker` creates a `Shipment` record and decrements `StockItem#quantity` in the same operation. For this to be safe under concurrency, both writes need to happen inside a single database transaction. Without that, another worker could read stale inventory between the two writes.

**The need:** Busybee should provide a hook — middleware, callback, or configuration — that lets users wrap each job's `perform` execution in application-level concerns like database transactions. Something like:

```ruby
# Hypothetical API
Busybee.configure do |config|
  config.around_perform do |job, &block|
    ActiveRecord::Base.transaction { block.call }
  end
end
```

This is a common pattern in job frameworks (Sidekiq's server middleware, etc.). Without it, every worker that does multi-record writes has to manually wrap its own `perform` body in a transaction, which is error-prone and easy to forget.

**For the demo app:** We'll wrap the relevant workers' `perform` methods in `ActiveRecord::Base.transaction` blocks directly. This works but is the kind of boilerplate the framework should eliminate.
