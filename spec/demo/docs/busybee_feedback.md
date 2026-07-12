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

---

## Pipeline throughput analysis and instrumentation needs

**Discovered during:** High-speed stress testing (DEMO_SPEED=50)

**Context:** At speed 50, the demo creates ~4.2 orders/sec. Each order enters a multi-step BPMN pipeline (`prepare_order` → `ship_order`), where each step is a separate Zeebe job handled by a busybee worker. We observed orders piling up in "submitted" status (1,000+ backlog) and needed to identify the bottleneck.

**What we found:** The bottleneck was `LoadItemAvailabilityWorker` — a fan-out step that runs once per item in an order (~6.5 times per order on average). Because busybee processes one job at a time per worker type (single stream per type), this worker was saturated at ~21.7 jobs/sec, capping pipeline throughput at ~3.3 orders/sec (21.7 ÷ 6.5). Individual job processing time was ~46ms (gRPC receive + DB query + gRPC complete), which is reasonable per-job, but the serial fan-out across ~6.5 items made it the slowest stage.

Non-bottlenecked workers confirmed this diagnosis:

- `LoadWarehousesWorker` runs once per order at the *start* of each process instance, in parallel with item availability checks, and isn't blocked by anything upstream. It ran at **3.9 jobs/sec** — close to the 4.2/sec creation rate, confirming it was keeping up with input.
- Downstream once-per-order workers (`PlanShipmentsWorker`, `MarkOrderPreparedWorker`) ran at **3.4 jobs/sec** — matching the throughput exiting the bottleneck, not the input rate. Their inter-job intervals were highly variable (75–1,800ms) showing they were starved for work, not slow.
- Other fan-out workers (`CalculateDistanceWorker` at 22.1 jobs/sec) showed the same ~45ms per-job time, confirming the per-job overhead is consistent and the bottleneck is structural (fan-out × per-job cost), not a slow worker.

**How we analyzed it:** This required manual log archaeology — there's no built-in way to see per-worker throughput or identify bottlenecks:

1. **Per-worker job counts**: Grepped docker container logs for each worker's completion signature (e.g., `"available at"` for LoadItemAvailability, `"Loaded 4 warehouses"` for LoadWarehouses) and counted occurrences in a 5-minute window.
2. **Inter-job intervals**: Extracted timestamps from consecutive log lines for the same worker type, computed deltas. Saturated workers showed consistent tight intervals (20–45ms); starved workers showed high variance (75–1,800ms).
3. **Cross-worker comparison**: Comparing a bottleneck-parallel worker (LoadWarehouses at 3.9/sec) against bottleneck-downstream workers (PlanShipments at 3.4/sec) confirmed the pipeline model.

**The need — instrumentation hooks:** Busybee should make this analysis trivial rather than requiring log scraping. Specifically:

- **Per-worker-type throughput metrics**: Jobs completed per second, rolling average. Exposed as a Prometheus endpoint, log line, or callback.
- **Per-job timing breakdown**: Time waiting in Zeebe queue, time in `perform`, time for gRPC completion. This distinguishes "worker is slow" from "worker is starved."
- **Saturation detection**: When a worker's inter-job idle time drops near zero, it's saturated — that's the bottleneck. A metric like `idle_fraction` per worker type would make bottlenecks immediately visible.
- **Pipeline throughput view**: For BPMN processes with multiple steps, the ability to see throughput at each stage and identify where backpressure builds.

An `around_job` or `on_job_complete` hook that receives timing metadata would let users build dashboards, emit StatsD metrics, or simply log structured data:

```ruby
# Hypothetical API
Busybee.configure do |config|
  config.on_job_complete do |event|
    event.worker_class    # => "Logistics::LoadItemAvailabilityWorker"
    event.duration_ms     # => 46  (time in perform)
    event.queue_wait_ms   # => 12  (time between Zeebe activation and perform start)
    event.total_ms        # => 58  (end-to-end including gRPC completion)
  end
end
```

**For the demo app:** We relied on `docker compose logs --timestamps` and grep/awk to reconstruct this picture. It worked but took significant effort and wouldn't scale to production debugging.

---

## Optional output variables

**Discovered during:** Unifying status workers with BPMN headers

**Context:** We consolidated 3 separate `MarkShipment*Workers` into a single `UpdateShipmentStatusWorker` that receives the target status via a BPMN header. Two of the original workers returned boolean outputs (`first_in_transit`, `all_delivered`) used by downstream exclusive gateways, while the third (`packed`) had no outputs.

The unified worker declares both outputs, but busybee requires all declared outputs to be returned from `perform` every time. So the `packed` path must return `{ first_in_transit: nil, all_delivered: nil }` even though those values are meaningless in that context.

**The problem:** Without I/O mapping in the BPMN to filter outputs, those nil values leak into the process instance variable space. A worker that only conditionally produces a value has no way to say "I don't have this output" — it must always return something, and nil pollutes the variable scope.

**The need:** Support for optional output variables that are only written to the process instance when the worker explicitly returns them:

```ruby
# Hypothetical API
output :first_in_transit, type: :boolean, optional: true
output :all_delivered,    type: :boolean, optional: true
```

When an optional output is omitted from the return hash (key absent, not just nil), busybee would skip it in the `complete_job` variables payload. This lets a single worker serve multiple BPMN tasks that need different subsets of its outputs, without requiring every BPMN task to add ioMapping to filter out irrelevant variables.

**For the demo app:** The unified worker always returns both keys (nil for irrelevant ones). The BPMN tasks that don't need a particular output rely on downstream gateways ignoring nil, which works but is fragile — a nil `first_in_transit` could confuse a gateway condition that doesn't explicitly handle it.

---

## Publishing messages from workers

**Discovered during:** Rearchitecting driver assignment to use BPMN message correlation

**Context:** The `CompleteDriverDeliveryWorker` needs to publish a `driver_available` BPMN message after releasing a driver, to unblock a process instance that's waiting at an intermediate message catch event. This is a natural pattern: a worker in one process instance completing work that should wake up a different process instance.

**The friction:** Workers have no access to the Zeebe client. The `Job` stores `@client` privately (used internally for `complete!`/`fail!`), and `Worker` doesn't expose it. To publish a message, we had to instantiate a separate `Busybee::Client.new` inside the worker — creating a second gRPC connection to do something the existing connection could handle.

**What made it harder than it should have been:**

1. **Discoverability**: Finding `Busybee::Client#publish_message` required reading source code. The method is well-documented in `lib/busybee/client/message_operations.rb`, but there's no user-facing guide that says "here's how workers communicate across process instances." The concept of message correlation is central to BPMN, so this should be a prominent topic in docs.

2. **Parameter inconsistency between client and testing helper**: The client uses `vars:` and `ttl:` (accepts `ActiveSupport::Duration`). The testing helper uses `variables:` and `ttl_ms:` (integer only). This is a paper-cut — you write the test with one API shape, then the production code with a different one. Aligning them (or at least cross-referencing them in docs) would reduce confusion.

3. **No guidance on client instantiation from workers**: `Busybee::Client.new` works because the Railtie sets up credential config (`config.x.busybee.cluster_address`, `config.x.busybee.credential_type`). But this isn't documented anywhere a worker author would find it. We only knew it worked because we saw `Busybee::Client.new` in the demo's service objects and inferred it would pick up the same config.

**The need:** Two things would help:

1. **Expose the client on the job** (or provide a class-level accessor): Workers that need to publish messages, set variables, or cancel instances shouldn't need to create a separate connection. Even a simple `Busybee.client` singleton would be better than requiring `Busybee::Client.new` (which creates a new gRPC channel each time).

```ruby
# Hypothetical: reuse the existing connection
class MyWorker < Busybee::Worker
  def perform
    # ... do work ...
    job.client.publish_message("event_name", correlation_key: id, vars: { foo: "bar" })
  end
end
```

2. **A "Message Correlation" guide in user docs**: Cover the pattern (worker publishes → catch event receives), show the BPMN setup (message definition, subscription, correlation key), show the Ruby side (client.publish_message), and explain TTL. This is one of the most powerful BPMN patterns and busybee already supports it — it just needs a spotlight.

**For the demo app:** We use `client.publish_message(...)` inside the worker's `perform` method. The `client` method is delegated through Worker → Job → the Client instance that fetched the job, reusing the existing gRPC connection.

---

## Worker readiness signal for container orchestration

**Discovered during:** Debugging cold-start timeouts in the smoke test

**Context:** The demo's Docker Compose stack runs 4 worker containers (one per domain). The `clockwork` container (which creates orders) needs to start *after* all workers are healthy and streaming jobs. Without a readiness signal from busybee, there's no reliable way to know when a worker is actually connected to Zeebe and processing — only that the OS process is alive.

**The problem:** Docker Compose healthchecks need a concrete signal to gate `depends_on: condition: service_healthy`. The best we can do today is `kill -0 1` (PID 1 alive) with a generous `start_period`, which is a rough proxy — the process could be alive but still booting Rails or waiting for Zeebe. This led to orders arriving before workers were streaming, causing early burst backlog and timeout failures in the smoke test.

**The need:** Busybee should emit a readiness signal once all configured workers are connected and streaming. Two natural options:

1. **Readiness file**: Write a file (e.g., `/tmp/busybee-ready`) when all worker streams are established. Docker healthcheck becomes `test -f /tmp/busybee-ready`. This is the pattern used by Puma (`--control-url`), Sidekiq (`config.alive_url`), and Kubernetes readiness probes.

```ruby
# Hypothetical: busybee CLI writes a readiness file
busybee --config config.yml --ready-file /tmp/busybee-ready
```

2. **Readiness HTTP endpoint**: Expose a lightweight HTTP server on a configurable port (e.g., `--ready-port 9292`) that returns 200 once streaming. More standard for Kubernetes liveness/readiness probes.

Option 1 is simpler and sufficient for Docker Compose. Option 2 is better for Kubernetes. Both could coexist.

**For the demo app:** We use `kill -0 1` with `start_period: 30s` as a rough healthcheck, and make clockwork depend on all workers being healthy. It works but can't distinguish "process alive" from "worker streaming."

---

## An `on_job_resolved` hook for asynchronous completion

**Discovered during:** Mission 7.5 (demo control-center dogfooding)

**Context:** The Monitoring recorder wants each job's *final outcome* (complete / failed / error). Today it reads status in `on_job_executed` — but that hook fires when `perform` returns, which for an async worker is *before* the work finishes. The Sim workers dispatch to a `Concurrent::Promises` future and resolve (`complete!`/`fail!`) from a background thread much later. No hook fires at that resolution, so every async job was recorded stuck in `ready`.

**The need:** A lifecycle hook that fires when a job is actually resolved, regardless of which thread or how much later:

```ruby
# Hypothetical API
Busybee.configure do |config|
  config.on_job_resolved { |job| Metrics.record(job.status, job.key) }
end
```

This is the missing member of the job-lifecycle set — `activated` and `executed` bracket the *synchronous dispatch*, but nothing observes the *deferred completion*. It becomes structurally necessary in the async worker era (v0.5): once `perform` routinely returns before the work is done, `on_job_executed` stops being a completion signal for anyone.

**For the demo app:** We fold it ourselves — the recorder's `after_call` maps the resolution RPC (`complete_job` → `complete`, etc.) back onto the run, relying on the fact that a job's own engine calls self-correlate their `job_key` on any thread. It works, but it's inferring a lifecycle moment from a *call*, which is exactly the signal a first-class hook should provide.

---

## Hooks may be interrupted — spawned threads need an owner

**Discovered during:** Mission 7.5 (the Multi shutdown wedge)

**Context:** The recorder offloads writes to a `Concurrent::SingleThreadExecutor` spawned from hook code. When a worker container exits (here, a rollover), Ruby's shutdown runs `at_exit` handlers, then *kills* surviving threads, then runs finalizers. A writer thread killed mid-SQLite-write left the connection's native mutex locked, and the finalizer that closes the database deadlocked — the process became unkillable, passed its liveness check, and starved its whole domain until a hard restart.

**The observation:** `safe: true` protects busybee's control flow from a hook *raising*, but nothing protects the process from a hook's *threads*. A thread outlives the hook call that spawned it and eventually dies by VM kill, wherever it happens to be standing. That ownership gap is the app's to close, but busybee is the natural place to *teach* it.

**The need:** Documentation, primarily — the hooks guide should state plainly that a hook that spawns background work owns that work's lifecycle, and show the drain pattern (an `at_exit` / `on_worker_shutdown` shutdown). Include the recognition signature of the failure (crash trace printed but the process still alive, SIGTERM inert, main thread parked in `pthread_mutex_lock` under `rb_objspace_call_finalizer`). Possibly, later, an affordance: a busybee-managed "run this on shutdown" registration so apps don't hand-roll the `at_exit`.

**For the demo app:** `Recorder.shutdown!`, registered `at_exit`, drains and stops the writer before the thread-kill step; `Recorder.flush` on `on_worker_shutdown` holds the graceful path until the final row lands. The demo now models the correct pattern — which is the worked example the docs should point to.

---

## Channel keepalive for silently-dropped streams — RESOLVED

**Discovered during:** Mission 7.5 (demo left running across host sleep/wake cycles)

**Context:** After the host suspended and resumed, workers went idle while Zeebe held hundreds of activatable jobs. The job-activation stream has no request deadline, so when its transport died silently (the suspend killed the TCP with no RST) the worker blocked in the stream read forever — alive and healthy-looking, activating nothing. Unary calls recovered on their own deadlines; only the deadline-less stream hung.

**Resolution:** Shipped as a gem feature this cycle — HTTP/2 channel keepalive (`grpc_keepalive_interval` / `grpc_keepalive_timeout`), so idle pings detect the dead transport and raise it as the gateway error the runner already recovers from. Left here for the record, as an example of the demo surfacing a real gem gap; no further action needed.
