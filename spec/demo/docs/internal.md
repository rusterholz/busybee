# Demo App Internals

Maintainer reference for the simulation engine, speed scaling, and fleet dynamics. For an overview of what the app does and how to run it, see the [README](../README.md).

## Simulation Architecture

The demo simulates an e-commerce fulfillment pipeline. Real-world delays (warehouse picking, driving) are replaced by time-scaled sleeps in the Sim workers.

**Order generation** is handled by Clockwork (`clock.rb`), which runs inside the `clockwork` Docker container (active only with the `auto` profile). It creates orders at a configurable rate using Faker-generated customer data and random items from the 15-item catalog.

**Tick/accumulator math**: Clockwork's minimum granularity is 1 second. At high speeds the scaled interval (`base_interval / speed`) drops below 1s, so the clock ticks every second and batch-creates orders. A fractional accumulator prevents drift:

```
tick = max(base_interval / speed, 1)
orders_per_tick = speed * tick / base_interval
```

Each tick, `accumulator += orders_per_tick`, then `batch = accumulator.floor` orders are created and the fractional remainder carries over.

**Catalog sampling**: Each order gets 3–10 random items from the 15-item catalog. The inventory is arranged so that every pair of warehouses misses exactly 2 items and every triple covers all 15 — this makes 3-shipment orders possible but 4-shipment orders impossible.

**Restocking**: `Sim::GuaranteedRestock` runs before each order enters the BPMN pipeline. It ensures enough inventory exists to fulfill the order, creating a sawtooth restocking pattern (generous restock when any warehouse runs low, partial restock otherwise).

**Worker rollovers**: the business workers recycle themselves like a rolling deploy, so the Monitoring dashboard shows a realistic incarnation history and busybee's graceful-shutdown path is exercised continuously. A non-Sim `around_perform` hook (in the busybee initializer) samples a time-rate hazard at each job boundary; when it fires it raises `Sim::Rollover`, a declared shutdown error that busybee turns into a graceful `:unhealthy` shutdown — and `restart: unless-stopped` brings the container back as a fresh incarnation with a new `worker_name`. Rolling *before* `perform` also fails the triggering job, so one hook simulates two production events at once: a rollout and an ordinary transient failure that the engine's retry then recovers. The hazard rises with the worker's `uptime_s` and is computed entirely in sim-seconds, so jobs-per-rollover stays constant across `DEMO_SPEED` (mean time-to-roll is a few minutes per container at speed 1). Sim's own workers are exempt — recycling them mid-flight would stall the pipeline. Set `DEMO_ROLLOVERS=false` to disable rollovers for a stable watch session.

## Speed Scaling

`DEMO_SPEED` (set via `bin/demo start --speed N`, default 1) affects every time-dependent parameter:

| Parameter | Formula | Effect |
|-----------|---------|--------|
| Order creation rate | `base_interval / speed` (clamped to 1s ticks with batching) | Higher speed → more orders per second |
| Pick-and-pack delay | `item_count * 1.4s * jitter / speed` | Faster warehouse processing |
| Delivery delay | `distance * 1.5s * jitter / speed` | Faster deliveries |
| Fleet size | `round((4 * speed + 83) / 29)` drivers | Linear scaling — more drivers at higher throughput |

Jitter is uniform in `[0.8, 1.2)` for both Sim workers.

### Example Values

| Parameter | Speed 1 | Speed 10 | Speed 30 | Speed 50 |
|-----------|---------|----------|----------|----------|
| Order interval | 12s | 1.2s | 1s (2.5/tick) | 1s (4.2/tick) |
| Pick-and-pack (5 items) | ~7s | ~0.7s | ~0.23s | ~0.14s |
| Delivery (8 units) | ~12s | ~1.2s | ~0.4s | ~0.24s |
| Fleet size | 3 | 4 | 7 | 10 |

## Fleet Dynamics

The driver fleet is a fixed size, seeded at startup via `db/seeds.rb`. Fleet size scales linearly with speed: `round((4 * speed + 83) / 29)` — giving 3 drivers at speed 1 and 7 at speed 30.

**Assignment** (`AssignDriverWorker`): When a shipment needs a driver, the worker creates a `DriverRequest` record and tries to assign the available driver with the lowest total mileage. If a driver is available, it's assigned immediately and the process continues. If all drivers are busy, the worker returns nil driver info along with the request ID, and the BPMN process waits at an intermediate message catch event.

**Request fulfillment** (`CompleteDriverDeliveryWorker`): After completing a delivery, the worker releases the driver (adds mileage, clears assignment) and checks for queued `DriverRequest` records. If an open request exists, it claims the oldest one atomically (using `SELECT FOR UPDATE` via ActiveRecord's `lock` scope), assigns the driver to the new shipment, and publishes a `driver_available` BPMN message. This unblocks the waiting process instance via Zeebe message correlation.

**Message correlation**: The BPMN `deliver_shipment` process uses an exclusive gateway after `assign_driver` to check if a driver was assigned (`driver.id != null`). If not, an intermediate message catch event waits for a `driver_available` message correlated on the `DriverRequest` ID. The message payload carries `driver_id` and `driver_name`, which are mapped into the process variable space via I/O mappings.

**Idempotent retry**: `CompleteDriverDeliveryWorker` handles three retry states: (A) not yet processed (`current_shipment_id == shipment_id`), (B) released but no request claimed (`current_shipment_id == nil`), and (C) released and already reassigned to a queued request (`current_shipment_id` is a different shipment). The mileage addition is skipped if the driver was already released, and the message is re-published if a request was already claimed.

## Pipeline Throughput

The primary bottleneck is `LoadItemAvailabilityWorker` in the `prepare_order` process. Each order fans out to 3–10 availability checks (one per line item), and these are multi-instance but still limited by the Zeebe job poll interval and single-threaded worker execution. The logistics YAML config (`config/busybee/logistics.yml`) gives this worker a higher `max_jobs: 32` to help keep up.

**Diagnosing bottlenecks**: At high speeds, grep the logs for submitted backlog counts:

```bash
docker compose logs clockwork | grep submitted_backlog
```

A growing backlog means orders are being created faster than the pipeline can process them. To find which worker type is the bottleneck:

```bash
docker compose logs workers_logistics | grep -c "Loaded availability"
docker compose logs workers_logistics | grep -c "Created Shipment"
```

Compare rates: if availability checks lag behind order creation, that's the bottleneck.

**Expected throughput**: At speed 1, the pipeline processes roughly 1 order every 12 seconds. At speed 50, throughput peaks around 3–4 orders/second before the fan-out bottleneck becomes significant.

## Tuning Parameters

All constants with their formulas and derivation:

| Constant | Location | Value | Rationale |
|----------|----------|-------|-----------|
| `BASE_DELAY` (pick-and-pack) | `PickAndPackWorker` | 1.4s/item | ~7s for a 5-item order at speed 1 |
| `BASE_DELAY` (delivery) | `DeliveryRunWorker` | 1.5s/distance unit | ~12s for avg 8-unit delivery |
| Picker concurrency | `PickAndPackWorker::PICKERS` | 3 | Simulates 3 warehouse pickers |
| Fleet size | `db/seeds.rb` | `round((4*speed + 83) / 29)` | Linear scaling — 3 at speed 1, 7 at speed 30 |
| Message TTL | `CompleteDriverDeliveryWorker` | 30 seconds | Time window for message correlation before expiry |
| Order interval | `clock.rb` | `12/speed` seconds | Base order rate |
| Item count range | `clock.rb` | 3–10 items | Wide range for shipment count variety |
| `BASE_ROLL_SECONDS` | `Sim::RolloverPolicy` | 240s | Base mean time-to-roll, in sim-seconds |
| `UPTIME_SCALE` | `Sim::RolloverPolicy` | 180s | Uptime at which the roll hazard doubles |

## YAML Configuration

Worker containers use per-domain YAML config files (`config/busybee/<domain>.yml`) loaded via `busybee --config`. This replaces the earlier approach of listing worker class names on the command line in `docker-compose.yml`.

Each file demonstrates a different aspect of YAML configuration:

| File | What it shows |
|------|---------------|
| `oms.yml` | Basic worker listing — no per-worker overrides needed |
| `logistics.yml` | Global `max_jobs` default + per-worker override for the bottleneck worker |
| `delivery.yml` | Per-worker `worker_mode` selection (polling for pure computation) |
| `sim.yml` | Global `job_timeout` override for long-running workers |

Note that some worker settings remain in the DSL (e.g., Sim workers' `complete_job_on_success false`). These are intrinsic to the worker's behavior and shouldn't be overridden at deploy time. YAML config is for operational tuning — settings that might vary by environment or deployment.

## Monitoring & Lifecycle Hooks

The Monitoring domain demonstrates how an app consumes busybee's lifecycle hooks. It owns no business logic — it's a passive recorder plus a read-only control center — and it records all three of busybee's lifecycle nouns (job, worker, call), each surfaced on the dashboard.

**Data model.** Four tables in the dedicated `monitoring` database:

- `Monitoring::JobRun` — one row per job activation, keyed by Zeebe's `job_key` (unique index): type, source, buffer depth, status, timings, error, and the job's `tags`.
- `Monitoring::WorkerProcess` — one row per worker *incarnation*, keyed by `(worker_name, job_type)`. The demo gives each container a per-boot-random `worker_name`, so every restart or `Sim` rollover is a new row — the dashboard's incarnation history. Holds the worker's phase, counters, buffer gauges, and lifecycle timestamps.
- `Monitoring::CallMetric` — the low-cardinality **aggregate**: per `(metric_name, context_tags)` tuple it keeps count / min / max / EWMA / EWMV, so per-RPC and per-worker-class call stats stay O(tuples), not O(calls).
- `Monitoring::EngineCall` — the high-cardinality **twin**: the call's `logging_context` persisted as one row, ordered by a monotonic `seq`. Only job-correlated calls are recorded (a `job_key` marks a perform-phase call), so the table stays bounded at ~calls-per-job; fetch/poll calls stay aggregate-only.

The last two are the point of the exercise: they render busybee's **two-cardinality contract** — `context_tags` (grouping keys) fold into the aggregate, `logging_context` (measurements) into the per-call record.

**Hook registration.** All hooks live in one `Busybee.configure` block in `config/initializers/busybee.rb` (the brownfield-typical shape), fired by the runner with `safe: true` so a raised error can't disrupt job execution:

- **Job** — `on_job_activated` / `on_job_executed` → `JobRun`.
- **Worker** — the four lifecycle hooks (`on_worker_started`, `_stop_requested`, `_stopping`, `_shutdown`) → `WorkerProcess`; `after_call` also refreshes the worker row, so a worker that only fetches still shows live counters.
- **Call** — `after_call` folds every call into `CallMetric` and, when job-correlated, `EngineCall`.
- **Per-job transactions** — one `around_perform` per domain wrapping `perform` in a transaction on *that domain's* connection (e.g. `Oms::Record.transaction`); a base-class `ActiveRecord::Base.transaction` would wrap nothing now that each domain has its own connection. `complete_driver_delivery` (publishes a Zeebe message mid-`perform`) and the async `Sim` jobs are excluded.

**Async recording & shutdown.** Hooks fire inline on the runner thread, so `Recorder` must not block it: each hook **snapshots** its subject synchronously (the `Job` mutates as it progresses) and `post`s the write to a `Concurrent::SingleThreadExecutor`. One writer matches SQLite's one-writer-per-file model. Because a real sink is out-of-order and at-least-once, each write carries a `(lifecycle_rank, seen_at)` ordering key: the upsert refuses to regress a row a later observation already advanced, but a behind-arriving write may still gap-fill columns it uniquely owns. Recording is best-effort — a failed write is logged and dropped, never retried into the hot path.

The writer must also be **drained before the process exits**. Ruby's shutdown runs `at_exit` handlers, *then* kills surviving threads, *then* runs finalizers — and a writer thread killed mid-SQLite-write leaves the connection's native mutex locked, so the finalizer that closes the database deadlocks and the process never dies. `Recorder.shutdown!`, registered `at_exit`, drains and stops the writer before that thread-kill step; `Recorder.flush` on `on_worker_shutdown` additionally holds the graceful path until the final lifecycle row has landed.

**Resolution folding.** The async `Sim` workers call `complete!`/`fail!` from a background future — *after* `on_job_executed` has already recorded the run, and with no job hook firing at resolution time. So `after_call` folds the resolution RPC's outcome (`complete_job` → `complete`, `fail_job` → `failed`, `throw_bpmn_error` → `error`) back onto the `JobRun` at execution rank. This works because a job's own engine calls self-correlate — the resolution call carries its `job_key` on whatever thread it runs — so the fold knows which run to update. An async run's *status* therefore resolves correctly; only its durations reflect the synchronous dispatch, since the hooks bracket the dispatch, not the deferred future.

**Retention.** `Monitoring::Prune` (run by clockwork every 60s) deletes worker rows and stuck-`ready` runs whose `updated_at` is older than ten minutes, so the incarnation history stays bounded rather than growing without limit.

**The control center.** `MonitoringController` renders a dark dashboard (`data-theme="dark"` on the `monitoring` layout, so only this area is dark) that auto-refreshes every 5 seconds via `<meta http-equiv="refresh">`; filters ride the query string so they survive the refresh. It has:

- **Lifecycle tiles** — Ready / Failed / Error / Complete / Total across the filtered runs.
- **Worker list** — filterable by phase (default `running`), domain, and job type; each row links to a per-worker **show page** (lifecycle moments with gap-diffs, gauges, full error, and that incarnation's own call log).
- **Job list** — filterable by type, status, domain, and process; the recent-runs table (capped at ~10) shows each run's timings and unfolds the gRPC calls it made as inline pills, and each run links to a per-run **show page** (timing tiles, the verbatim tag table, and the ordered call sequence, cross-linked back to the workers that made each call).
- **Engine-call rollups** — `CallMetric` aggregated by RPC and by worker class.

`Monitoring::Stats` computes the headline numbers over the filtered scope; duration means are taken over resolved rows only (`status != "ready"`), so async dispatch-time near-zeros don't drag them down.

## Test Hardpoints

### Smoke Test: `bin/demo test`

Self-contained smoke test that starts a fresh stack at speed 30, runs orders through the pipeline, and tears down:

```bash
bin/demo test           # 25 orders (default)
bin/demo test 20        # 20 orders
```

This is the primary verification command for gem maintainers — run it after completing a mission and before pushing.

### Integration Test: `demo:run_orders[count]`

The underlying rake task used by `bin/demo test`. Useful when the stack is already running:

```bash
bin/rails demo:run_orders[50]          # Create 50 orders, verify all complete
bin/rails demo:run_orders[10]          # Quick smoke test
```

**What it verifies**:
- All orders reach "fulfilled" status within the timeout
- All shipments reach "delivered" status
- All drivers are released (no dangling assignments)
- Inventory was decremented (stock items have been consumed)

**Expected timing**: At speed 1, each order takes roughly 30–60 seconds to complete. At speed 50, orders complete in ~1–2 seconds. The task uses a polling timeout of `count * 300 / speed` seconds (clamped to a minimum of 30s).

**How outer busybee specs connect**: The busybee gem's Railtie specs already load the demo app's environment (`spec/demo/config/environment.rb`). The rake task can be invoked from busybee's spec suite:

```ruby
system("cd spec/demo && bin/rails demo:run_orders[100]") or fail "Demo orders did not complete"
```

This tests busybee end-to-end: process deployment, worker execution, variable passing, multi-instance fan-out, and conditional routing — all exercised through a realistic application rather than synthetic fixtures.

### Worker Unit Tests

Worker specs live in `spec/workers/` and use the busybee gem's testing helpers (`require "busybee/testing"`). Two patterns:

**Matcher pattern** (preferred for most workers): Uses `fail_job`, `complete_job`, and `throw_bpmn_error_on` matchers with `let`-based job setup. See `calculate_distance_worker_spec.rb`, `update_order_status_worker_spec.rb`, and `update_shipment_status_worker_spec.rb`.

```ruby
let(:job) { build_test_job(variables: variables, headers: headers) }

it "completes the job" do
  expect(described_class).to complete_job(job).with_vars(hash_including(distance: 5.0))
end
```

**Direct pattern** (for client interaction testing): Uses `build_test_job` + `execute_worker` directly when you need to stub or assert on the underlying client (e.g., `publish_message`). See `complete_driver_delivery_worker_spec.rb` for an example.

## Creating Orders Programmatically

The web UI at `/orders/new` is the simplest way to create orders. For scripting or testing without the UI, you can create orders via curl. The form uses Rails CSRF protection, so you need a cookie jar:

```bash
# Get a session cookie and CSRF token
COOKIE_JAR=$(mktemp)
TOKEN=$(curl -s -c "$COOKIE_JAR" http://localhost:3000/orders/new \
  | grep 'name="authenticity_token"' \
  | grep -o 'value="[^"]*"' | head -1 \
  | sed 's/value="//;s/"//')

# POST the order
curl -s -X POST http://localhost:3000/orders \
  -b "$COOKIE_JAR" \
  -d "authenticity_token=${TOKEN}" \
  -d "order[customer_name]=Test+Customer" \
  -d "order[address_line_1]=123+Main+St" \
  -d "order[city]=Portland" \
  -d "order[state]=OR" \
  -d "order[zip]=97201" \
  -d "order[lat]=2.5" \
  -d "order[lon]=-3.0" \
  -d "items[wireless-mouse][qty]=1" \
  -d "items[usb-c-hub][qty]=1" \
  -d "items[laptop-stand][qty]=1" \
  -L  # follow redirect to order show page

rm -f "$COOKIE_JAR"
```

Item types are from the 15-item catalog defined in `config/initializers/demo.rb`. Coordinates should be in the range `[-9.0, 9.0]` to land near the warehouses.

For bulk order creation in a running Docker stack, prefer the `demo:run_orders` rake task (see Test Hardpoints above) — it bypasses the web layer and creates orders directly via ActiveRecord.

## Known Limitations

- **Single-threaded per worker type** (MRI Ruby). The Sim workers work around this with `Concurrent::Promises` futures, but other workers process one job at a time. This is fine for the demo's throughput but wouldn't scale for production.
- **SQLite as single-node store**. WAL allows concurrent reads but serializes writes *per file*. Splitting into one database per domain removes cross-domain contention, and the monitoring sink writes asynchronously to its own file; within a single domain, writes still serialize, so that domain's own write rate is its ceiling at very high speeds.
- **Fixed fleet size**. The driver fleet is seeded at startup and doesn't scale dynamically. The checkout/wait queue handles burst load gracefully, but under sustained overload, orders queue up rather than triggering new driver creation.
- **No BPMN call activities for process chaining**. The `prepare_order` → `ship_order` → `deliver_shipment` chain uses ActiveRecord callbacks instead. This is pragmatic (call activities require parent process awareness of child details) but means the chain isn't visible in a single BPMN diagram.
- **Inventory is guaranteed**. `GuaranteedRestock` ensures every order can be fulfilled. This makes the demo reliable but removes the "out of stock" scenario that a real system would need to handle.
- **Logistics runs more workers than its connection pool**. The logistics process runs 6 workers against a pool of 5 (`database.yml`), so busybee logs a pool-size warning at boot and, under load, a worker can briefly wait on a connection. Harmless at the demo's throughput; the fix is to size the pool to at least the worker count (e.g. via `RAILS_MAX_THREADS`).
