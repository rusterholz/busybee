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

---

## CLI runner should log to STDOUT by default (or offer a flag)

**Discovered during:** Docker containerization of the demo app

**Context:** When running workers via `bundle exec busybee`, all `Rails.logger` output goes to `log/development.log` — a file. In Docker containers, this means `docker compose logs` shows nothing from the workers, even though they're actively processing jobs. The web server (Puma) has its own stdout output, so its logs appear, but the workers are completely silent.

This is particularly confusing for new users running the demo: jobs complete successfully but the containers look dead. We had to add `RAILS_LOG_TO_STDOUT=true` to the Docker environment and a conditional `config.logger = ActiveSupport::Logger.new($stdout)` in the Rails config.

**The need:** The `busybee` CLI should either:
1. Default to STDOUT logging when it detects a TTY or Docker environment, or
2. Accept a `--log-to-stdout` flag (or `-v` for verbose), or
3. Always broadcast to STDOUT in addition to the configured Rails logger

Option 3 is how Puma behaves — it writes to both the Rails log and stdout. This is the least surprising behavior for a process manager that users run in a terminal or container.

```ruby
# Hypothetical: busybee CLI auto-configures STDOUT broadcast
Busybee::CLI.main(ARGV) # internally sets up STDOUT broadcast when Rails.logger points to a file
```

**For the demo app:** Added `RAILS_LOG_TO_STDOUT` env var to docker-compose.yml and a conditional logger override in `development.rb`. Works, but every busybee user deploying to Docker will hit this same gotcha.
