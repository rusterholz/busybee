# Busybee Demo: Dropship Co.

A multi-domain e-commerce fulfillment system orchestrated by BPMN workflows, built on [busybee](https://github.com/busybee-org/busybee). Orders flow through warehouse planning, pick-and-pack simulation, driver assignment, and delivery — all coordinated by Zeebe with busybee workers doing the actual work.

For reference documentation on the busybee features used here, see [Workers](../../docs/workers.md) (defining, running, and testing workers) and [Gem Configuration](../../docs/configuration.md) (connection, credentials, and defaults).

## Quick Start

```bash
bin/demo start              # Auto-ordering at speed 1 (one order every ~12s)
bin/demo start --speed 10   # 10x faster — useful for stress testing
bin/demo start --manual     # No auto-ordering — create orders through the UI
```

Open [localhost:3000](http://localhost:3000). The dashboard shows order counts by status; click into individual orders to watch shipments progress from planned → packed → in transit → delivered. The **Monitoring** link in the nav opens a separate dark dashboard showing what busybee itself is doing — every job run, worker process, and gRPC call, with timings and status. Filter the job and worker lists, or click any worker or run for its detail page.

Other commands:

```bash
bin/demo stop       # Stop containers, keep data
bin/demo clean      # Stop and destroy everything
bin/demo test       # Smoke test: start, run 25 orders, tear down
bin/demo status     # Show containers + order status counts
```

`bin/stop`, `bin/clean`, and `bin/status` are shortcuts for the corresponding `bin/demo` subcommands.

## Business Domains

Dropship Co. has separate services for its three core business domains, plus two behind-the-scenes domains:

- **OMS** — Order Management System. Owns orders and their lifecycle status.
- **Logistics** — Warehouses, inventory, and shipment planning.
- **Delivery** — Driver fleet management and delivery execution.
- **Sim** — Simulates physical processes (pick-and-pack, driving) with time-scaled delays.
- **Monitoring** — Operational observability. Records every job busybee runs, every worker process, and every gRPC call it makes — timings, status, tags — and surfaces them on a separate dark dashboard. This is what *busybee* is doing, as distinct from what the *business* is doing.

Each business domain has its own models, workers, and namespace. They communicate only through BPMN process variables — no cross-domain model references. Monitoring is a passive observer: it owns no business logic and writes nothing the workflows read.

## BPMN Processes

Three BPMN processes chain together to fulfill an order. Each demonstrates different orchestration patterns.

### `prepare_order`

Triggered when an order is created. Plans which warehouses will fulfill which items.

This process demonstrates **fan-out/fan-in with data enrichment** — loading data from multiple sources in parallel, enriching each element with computed data, then merging everything for a planning step:

1. **Parallel split** into two independent data-loading branches
2. **Branch A**: Load all warehouses, then a **multi-instance subprocess** calculates the distance from each warehouse to the delivery address (enriching each warehouse object with its `.distance`)
3. **Branch B**: A **multi-instance subprocess** checks item availability across warehouses for each line item (enriching each item with its `.warehouse_ids`)
4. **Parallel join** — all distance and availability data now in scope
5. **Plan shipments** — a single worker optimizes shipment groupings given the enriched data
6. **Multi-instance subprocess** creates each planned shipment (decrementing inventory)
7. **Update order status** → "processing" — transitions status via a BPMN header

### `ship_order`

Triggered when the order reaches "processing" status (via an ActiveRecord callback that chains the two processes).

This process demonstrates **sequential multi-instance** — iterating over a collection where each element goes through a multi-step pipeline:

1. Load all shipments for the order
2. **Multi-instance subprocess** over shipments — each one gets:
   - `simulate_pick_and_pack` — a non-blocking worker that simulates warehouse picking delay proportional to item count (demonstrates workers with **custom job lifecycle management**)
   - `update_shipment_status` → "packed" — triggers the next process via callback
3. Update order status → "packed"

### `deliver_shipment`

Triggered per-shipment when it reaches "packed" status. The most complex process.

This process demonstrates **BPMN message correlation**, **conditional branching**, and **cross-process coordination**:

1. **Parallel split**: load delivery address + calculate distance (Branch A) while assigning a driver (Branch B — creates a `DriverRequest` and assigns immediately if a driver is available)
2. **Exclusive gateway**: if no driver was available, the process waits at an **intermediate message catch event** for a `driver_available` message (published by `CompleteDriverDeliveryWorker` when another delivery finishes)
3. **Parallel join** — driver assigned, distance known
4. Update shipment status → "in_transit", returning whether this is the **first shipment in transit** for the order
5. **Exclusive gateway**: if first in transit, update order status → "shipping" (demonstrates **conditional routing** based on worker output)
6. `simulate_delivery_run` — non-blocking distance-proportional delay
7. **Parallel split** for post-delivery: update shipment status → "delivered" and check if **all shipments are delivered** (Branch C, with a conditional gateway to update order status → "fulfilled") while recording driver mileage, releasing the driver, and **fulfilling queued driver requests** (Branch D)

## Workers at a Glance

| Worker | Domain | What it demonstrates |
|--------|--------|---------------------|
| `LoadOrderAddressWorker` | OMS | Simple data loading — reads one model, outputs coordinates |
| `UpdateOrderStatusWorker` | OMS | **Header-driven status transitions** — a single worker handles all order status changes (`processing`, `packed`, `shipping`, `fulfilled`), receiving the target status via a BPMN `header` and validating against an allowlist |
| `LoadWarehousesWorker` | Logistics | Returns a **collection** as a process variable (array of warehouse objects) |
| `LoadItemAvailabilityWorker` | Logistics | Per-item availability check used inside a **multi-instance subprocess** — shows how each instance enriches its element |
| `PlanShipmentsWorker` | Logistics | **Pure computation worker** — receives enriched data, runs a greedy optimization algorithm, returns planned shipments. No database access. |
| `CreateShipmentWorker` | Logistics | **Transactional worker** — creates a shipment and decrements inventory atomically; the transaction is supplied by the demo's `around_job` hook (see [Lifecycle Hooks](#lifecycle-hooks)), not opened by the worker |
| `LoadOrderShipmentsWorker` | Logistics | Cross-domain data loading (reads shipments for an OMS order ID) |
| `UpdateShipmentStatusWorker` | Logistics | **Header-driven status transitions** with **conditional outputs** — handles `packed`, `in_transit`, and `delivered` via a BPMN header, returning `first_in_transit` or `all_delivered` booleans depending on the transition |
| `CalculateDistanceWorker` | Delivery | **Header-driven behavior** — reads `algorithm` from the job header to select computation strategy |
| `AssignDriverWorker` | Delivery | **Request-based assignment with BPMN message correlation** — creates a `DriverRequest`, assigns a driver if available, or returns nil to trigger a message catch event in the BPMN |
| `CompleteDriverDeliveryWorker` | Delivery | **Request fulfillment and message publishing** — records mileage, releases the driver, then claims the oldest queued `DriverRequest` and publishes a `driver_available` message to unblock a waiting process instance |
| `PickAndPackWorker` | Sim | **Non-blocking worker with custom job lifecycle** — runs delays in `Concurrent::Promises` futures, manages its own `complete_job`/`fail_job` calls, uses a semaphore to limit concurrent pickers |
| `DeliveryRunWorker` | Sim | **Semaphore-limited concurrency** — lazy-loads permit count from Driver table, limits concurrent delivery simulations to fleet size |

## Lifecycle Hooks

The app configures busybee **lifecycle hooks** — the same extension points a production app would use to plug in observability or cross-cutting behavior. They're all registered in one `Busybee.configure` block in `config/initializers/busybee.rb`, the way you'd wire busybee into a brownfield app:

- **Observability** — the demo records all three of busybee's lifecycle nouns: job hooks (`on_job_activated`/`on_job_executed`) into `Monitoring::JobRun`, worker hooks (`on_worker_started` through `on_worker_shutdown`) into `Monitoring::WorkerProcess`, and `after_call` into per-call and aggregate call records. This is the demo's stand-in for a Datadog/OpenTelemetry sink. The runner fires these hooks safely (a failure can't disrupt job execution), and the recorder offloads each write to a single background thread, so recording never blocks job processing. Monitoring has its own database, so the sink never contends with business writes.
- **Per-job transactions** — `around_job` hooks wrap specific jobs' `perform` in a transaction on their domain's database, so their writes commit atomically. They're registered one per domain (the `job_type` array filter covers logistics' two transactional jobs in one go), each transacting on its own connection — not globally, because a blanket wrapper is wrong for some workers: `complete_driver_delivery` publishes a Zeebe message mid-`perform` (a transaction can't roll that back), and the Sim workers are async (their `perform` returns immediately and the real work runs in a background future, so a transaction around it would be a no-op). The covered jobs no longer open transactions themselves.

One honest wrinkle the Monitoring view surfaces: the async Sim workers finish in a background future *after* their job hooks have fired, so the dashboard shows their `perform` as near-instant. Their final status still lands correctly — the completion call they make when the future resolves is folded back into the run — but the timing reflects the synchronous dispatch, not the deferred work. It's an accurate window into how hooks observe an async `perform`.

## Architecture

Docker Compose runs the full stack: Zeebe (with Elasticsearch for storage), a Rails web server, 4 worker processes (one per domain), and an optional clockwork process for auto-ordering.

- **Databases**: One SQLite database per domain (`oms`, `logistics`, `delivery`) plus one for `monitoring`, each its own file (WAL mode) in a Docker volume. Because SQLite serializes writes per file, separate databases let the domains — and the observability sink — write without contending, and more realistically model a distributed system. Each domain's models inherit a `connects_to` base class (e.g. `Oms::Record`); there are no cross-domain associations.
- **Workers**: Each domain runs as a separate `busybee` CLI process, configured via per-domain YAML files in `config/busybee/`. Workers are single-threaded (MRI), but the Sim workers use `Concurrent::Promises` for non-blocking delays.
- **YAML configuration**: Worker containers use `busybee --config config/busybee/<domain>.yml` instead of listing class names on the command line. Each YAML file defines which workers run in that process and any per-worker tuning (e.g., higher `max_jobs` for the bottleneck `LoadItemAvailabilityWorker`). See `config/busybee/` for examples, and [Workers: YAML Configuration](../../docs/workers.md#yaml-configuration) for the full reference.
- **Process chaining**: `prepare_order` → `ship_order` → `deliver_shipment` are chained via ActiveRecord `after_commit` callbacks, not BPMN call activities.
- **Speed scaling**: The `DEMO_SPEED` env var (set via `--speed` flag) scales all timing — order creation rate, worker delays, and fleet size.

See [docs/internal.md](docs/internal.md) for simulation architecture details, speed scaling formulas, and fleet dynamics rationale.
