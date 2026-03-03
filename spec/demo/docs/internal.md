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

## YAML Configuration

Worker containers use per-domain YAML config files (`config/busybee/<domain>.yml`) loaded via `busybee --config`. This replaces the earlier approach of listing worker class names on the command line in `docker-compose.yml`.

Each file demonstrates a different aspect of YAML configuration:

| File | What it shows |
|------|---------------|
| `oms.yml` | Basic worker listing — no per-worker overrides needed |
| `logistics.yml` | Global `max_jobs` default + per-worker override for the bottleneck worker |
| `delivery.yml` | Per-worker `runner_mode` selection (polling for pure computation) |
| `sim.yml` | Global `job_timeout` override for long-running workers |

Note that some worker settings remain in the DSL (e.g., Sim workers' `complete_job_on_success false`). These are intrinsic to the worker's behavior and shouldn't be overridden at deploy time. YAML config is for operational tuning — settings that might vary by environment or deployment.

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
- **SQLite as single-node store**. WAL mode allows concurrent reads, but writes are serialized. At very high speeds (50+), write contention on the shared SQLite database can become a bottleneck.
- **Fixed fleet size**. The driver fleet is seeded at startup and doesn't scale dynamically. The checkout/wait queue handles burst load gracefully, but under sustained overload, orders queue up rather than triggering new driver creation.
- **No BPMN call activities for process chaining**. The `prepare_order` → `ship_order` → `deliver_shipment` chain uses ActiveRecord callbacks instead. This is pragmatic (call activities require parent process awareness of child details) but means the chain isn't visible in a single BPMN diagram.
- **Inventory is guaranteed**. `GuaranteedRestock` ensures every order can be fulfilled. This makes the demo reliable but removes the "out of stock" scenario that a real system would need to handle.
