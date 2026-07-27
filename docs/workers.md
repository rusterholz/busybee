# Workers

In a distributed system, each application might need to participate in dozens of business processes that span the whole organization. Orchestration lets you meet that need by allowing each app to expose just a handful of domain-specific actions, and then reusing and composing those actions into different workflows which describe those business processes. Busybee's **Worker** abstraction lets you define those actions as simple Ruby classes, and handles everything else for you: connecting your class to the workflow engine, requesting work, reporting results, and managing the process lifecycle.

If you've used Sidekiq (or similar frameworks) to build background jobs, this pattern should feel very familiar. You define a class, implement a `perform` method, and let the framework handle the infrastructure. The key conceptual differences are:
- Background jobs in Sidekiq are always running in the same application that invokes them and defines them, while [Workers](https://docs.camunda.io/docs/components/concepts/job-workers/) in an orchestrated system are still running in the application that defines them, but they are always being invoked externally, by an instance of one of those business processes that is running in the central workflow engine.
- Background jobs work by side effects only (that is, the return value of `perform` in a Sidekiq job does not matter), but in a Worker both side effects and return values matter. The return values become part of the context of the running business process instance. This allows other downstream workers to consume those values, and also allows the workflow to make flow control decisions based on them.

Busybee is built around a workflow engine named [Zeebe](https://docs.camunda.io/docs/components/zeebe/zeebe-overview/), which is available in either self-hosted form or as a hosted/SaaS product from [Camunda](https://camunda.com/). The workflow definition format used by Zeebe and Camunda, and therefore what Busybee supports, is called [BPMN](https://docs.camunda.io/docs/components/modeler/bpmn/bpmn-primer/).

> For a working example of workers in a multi-domain system, see the [Dropship Co. demo app](../spec/demo/README.md), which uses busybee workers to orchestrate order fulfillment across isolated warehousing, logistics, and delivery domains.

## Table of Contents

- [Defining Workers](#defining-workers)
  - [Your First Worker](#your-first-worker)
  - [The Job Lifecycle](#the-job-lifecycle)
  - [Declaring Inputs](#declaring-inputs)
  - [Declaring Outputs](#declaring-outputs)
  - [Input/Output Types](#inputoutput-types)
  - [Advanced DSL Options](#advanced-dsl-options)
- [Running Workers](#running-workers)
  - [CLI Quick Start](#cli-quick-start)
  - [CLI Reference](#cli-reference)
  - [Rails Integration](#rails-integration)
  - [Signal Handling](#signal-handling)
  - [Worker Modes](#worker-modes)
  - [Multiple Workers in One Process](#multiple-workers-in-one-process)
  - [YAML Configuration](#yaml-configuration)
  - [Configuration Precedence](#configuration-precedence)
- [Testing Workers](#testing-workers)
  - [Setup](#setup)
  - [Basic Worker Testing](#basic-worker-testing)
  - [Inspecting Job State](#inspecting-job-state)
  - [Worker Testing Matchers](#worker-testing-matchers)
  - [Testing Best Practices](#testing-best-practices)

---

## Defining Workers

### Your First Worker

A worker is a Ruby class that subclasses `Busybee::Worker` and implements `perform`. Each time the workflow engine has a job ready, Busybee creates a new instance of your worker class for that job and calls `perform`:

```ruby
class ProcessOrderWorker < Busybee::Worker
  job_type "process_order"

  variable :order_id, type: :uuid

  output :confirmation_number, type: :string

  def perform
    order = Order.find(order_id)
    confirmation = order.process!

    { confirmation_number: confirmation }
  end
end
```

A few things are happening here:

- **`job_type`** identifies which jobs this worker handles. When the workflow engine reaches a [service task](https://docs.camunda.io/docs/components/modeler/bpmn/service-tasks/) with this type, it creates a job and sends it to an available worker. If you omit `job_type`, it's derived from the class name: `ProcessOrderWorker` becomes `"process_order"`.
- **[`variable`](#declaring-inputs)** declares an input your worker expects. Busybee defines an accessor method so you can call `order_id` directly in `perform`.
- **[`output`](#declaring-outputs)** declares what your worker returns. When `perform` returns a Hash, those values flow back into the workflow as [process variables](https://docs.camunda.io/docs/components/concepts/variables/) so that downstream workers may have access to them among their inputs.
- **[`perform`](#the-job-lifecycle)** contains your business logic. A new worker instance is created for each job, so you can safely use instance variables and private helper methods. (Note that perform takes no arguments.)

### The Job Lifecycle

While a Worker object knows how to perform units of work, a Job object represents one individual unit of that work to be performed. When a running [process instance](https://docs.camunda.io/docs/components/concepts/processes/#process-instance-creation) (a single execution of a workflow) arrives at the point where work needs to be done (a "[service task](https://docs.camunda.io/docs/components/modeler/bpmn/service-tasks/)" in BPMN terms), a job is created in the workflow engine with all of the context needed to perform that work. The job is called "created" or "available" when the workflow engine prepares it, and called "activated" or "ready" when it has been picked up by a running worker. At that point, the workflow engine waits for the worker to call back and report one of three possible outcomes:
- **Completed** - This is the happy path. If the work was performed successfully, the job is marked complete and optional additional data variables are sent back to the process instance, which continues to the next step in the workflow.
- **Failed** - If the work could not be performed (if a ruby exception was raised), the job is marked as failed, and after a short backoff delay it will be retried (made available again for another worker to pick it up).
  - The maximum number of retries is set by the [process definition](https://docs.camunda.io/docs/components/modeler/bpmn/service-tasks/#task-definition) (the BPMN document that describes the workflow); if it is exceeded, the entire running process instance is paused and an ["Incident"](https://docs.camunda.io/docs/components/concepts/incidents/) is raised in the workflow engine for an operator to review. The remaining number of retries on the current job can be read and updated as desired.
- **Errored** - If the work encountered an abnormal **business** condition (for example, insufficient funds) the job may do what is called _throwing a BPMN error._ This is different than a _Ruby error,_ which causes job failure and retry; BPMN errors should be used for flow control, when there's an anticipated business outcome that the workflow needs to handle by taking a different branch.

If none of those three things happen within a configurable window of time (the job timeout), the workflow engine assumes that the worker process must have crashed, and it will make the job available again for other workers to pick up. The deadline for the current job can also be read and updated as desired.

When a running busybee process receives a job, it uses your worker class to execute this lifecycle, with some additional checks and conveniences:

1. **Instantiation** - a new instance of your worker is created for that job.
2. **Input Validation** - all `required: true` inputs are checked. If any are missing, `MissingInput` is raised.
3. **Perform** - your `perform` method runs.
4. **On Success** - if `perform` returned successfully and `complete_job_on_success` is `true` (the default), then:
  - **Output Validation** - All `required: true` outputs are checked in the Hash returned from `perform`. If any are missing, `MissingOutput` is raised.
  - **Return Variables** - Busybee reports to the workflow engine that the job is complete, sending back any output values returned from `perform`.
5. **On Failure** - if `perform` raises an exception and `fail_job_on_error` is `true` (the default), then:
  - **Error Reporting** - Busybee reports to the workflow engine that the job failed, sending back the error class and message and the configured backoff delay.

This means that for most workers, you can just implement `perform`, return a Hash, and let Busybee handle the rest.

(For throwing a BPMN error, see the [Manual Lifecycle Control](#manual-lifecycle-control) section below.)

#### Automatic Completion

By default, Busybee completes the job when `perform` returns successfully. If `perform` returns a Hash, those key-value pairs become output variables:

```ruby
def perform
  order = Order.find(order_id)

  { status: order.status, processed_at: Time.now.iso8601 }
  # Job is completed automatically with these variables
end
```

If `perform` returns an empty Hash or anything other than a Hash (including nil), the job is completed with no output variables.

**Output Validation:** If one or more output variables were declared with `required: true` (the default) but those keys are not present in the returned Hash, a `MissingOutput` error will be raised.

#### Automatic Failure (Error Handling)

If `perform` raises an exception, Busybee reports the job as failed to the workflow engine, along with the error message. The job will then be retried after a configurable backoff delay, up to the maximum retry count set in the [BPMN process definition](https://docs.camunda.io/docs/components/modeler/bpmn/service-tasks/#task-definition) (not shown here):

```ruby
class ProcessPaymentWorker < Busybee::Worker
  variable :order_id, type: :uuid

  output :charged, type: :boolean

  backoff 30_000  # wait 30 seconds before the workflow engine makes this job available again

  def perform
    order = Order.find(order_id)   # may raise ActiveRecord::RecordNotFound
    PaymentGateway.charge(order)   # may raise PaymentGateway::Timeout

    { charged: true }
  end
  # If either line raises, the job is failed and retried after 30s
end
```

**Important:** Because failed jobs are retried by default, you should try to make your `perform` method [idempotent](https://en.wikipedia.org/wiki/Idempotence) whenever possible. If a particular worker cannot safely be retried, set retries to `0` in the BPMN definition. Even then, **Zeebe does not guarantee exactly-once execution.** If you need that guarantee, your worker must implement it.

#### Manual Lifecycle Control

For cases where automatic handling isn't sufficient, you can control the job lifecycle directly. The `complete!`, `fail!`, and `throw_bpmn_error!` methods are delegated from the worker to the job:

```ruby
class ProcessOrderWorker < Busybee::Worker
  complete_job_on_success false  # we'll handle completion ourselves

  def perform
    order = Order.find(order_id)

    case order.validate
    when :ok
      order.process!
      complete!(confirmation: order.confirmation_number)
    when :fraud_detected
      # this is a business-level error case -- the workflow will have a branch to handle this:
      throw_bpmn_error!(:fraud_detected, "Fraud detected for order #{order_id}")
    when :invalid_items
      # this is a technical failure -- if it cannot succeed on retry, the workflow needs to stop and alert the operator:
      fail!("Order contains invalid or unavailable items")
    end
  end
end
```

**`complete!(vars = {})`** completes the job with optional output variables.

**`fail!(error, retries: nil, backoff: nil)`** fails the job. Accepts a String or Exception. Optionally override the retry count or backoff delay.

**`throw_bpmn_error!(code, message = "")`** throws a [BPMN error](https://docs.camunda.io/docs/components/modeler/bpmn/error-events/) that can be caught by an [error boundary event](https://docs.camunda.io/docs/components/modeler/bpmn/error-events/#error-boundary-events) in the process definition. The error code can be a String, Symbol (converted to UPPERCASE), or Exception class (it will be converted from `MyApp::OrderNotFound` to the code string `MY_APP_ORDER_NOT_FOUND`). Use BPMN errors when the failure is an anticipated business outcome that the workflow should handle, rather than a technical failure that should be retried.

**`update_retries(count)`** and **`update_timeout(duration)`** modify the job's retry count or lock timeout without completing or failing it. Useful for long-running jobs that need to extend their deadline:

```ruby
def perform
  update_timeout(5.minutes)  # extend deadline before starting long operation
  # ... long operation ...
end
```

Note that you can safely mix-and-match manual and automatic control, because both automatic completion and automatic failure check whether the job is still `ready?` before they attempt to complete or fail it. Therefore, this is a perfectly valid alternate approach to the above:

```ruby
class ProcessOrderWorker < Busybee::Worker
  def perform
    order = Order.find(order_id)

    case order.validate
    when :ok
      order.process!
      return { confirmation: order.confirmation_number } # will trigger auto-complete
    when :fraud_detected
      throw_bpmn_error!(:fraud_detected, "Fraud detected for order #{order_id}") # marks the job non-ready, so auto-complete is skipped
    when :invalid_items
      raise "Order contains invalid or unavailable items" # will trigger auto-fail
    end
  end
end
```

#### Shutdown Handling

Some exceptions represent conditions that a worker container can't recover from: a lost database connection, a broken Redis pool, a revoked API credential. When one of these occurs, it's better to shut down the worker process so that your container manager (e.g. kubernetes) can replace it with a fresh one.

Use `shutdown_on` to declare which exception classes should trigger a graceful shutdown:

```ruby
class ProcessOrderWorker < Busybee::Worker
  shutdown_on PG::ConnectionBad
  shutdown_on Redis::ConnectionError

  def perform
    # If this raises PG::ConnectionBad, the worker shuts down gracefully
    Order.find(order_id).process!
  end
end
```

You can also configure shutdown errors globally for all workers in your application via [`Busybee.shutdown_on_errors`](configuration.md).

`shutdown_on` accepts only `StandardError` subclasses. Classes outside that hierarchy (e.g., `Interrupt`, `NoMemoryError`, `LoadError`) raise an error at class-definition time, because the per-job rescue that consults `shutdown_on` is `StandardError`-scoped — a non-`StandardError` would never reach the check at runtime. Signal-class errors are handled separately via the CLI's signal traps; there's nothing to configure here.

When a shutdown is triggered, the worker process stops requesting new jobs, fails any in-flight jobs (preserving their retry count so they'll be picked up by another worker), and exits. [Worker lifecycle hooks](hooks.md#worker-hooks) observe the whole sequence, with the closing snapshot reporting [`reason: :unhealthy`](hooks.md#stop-reasons).

#### Direct Job Access

Several of the methods you've already seen — `complete!`, `fail!`, `throw_bpmn_error!`, `update_retries`, `update_timeout`, `variables`, and `headers` — are actually delegated from the worker to an underlying `Busybee::Job` object. You can access this object directly via `self.job` in `perform`. The job carries metadata, raw data, and status information that isn't available at the worker level:

```ruby
def perform
  # Metadata (job-only)
  job.key                     # unique job identifier (Integer)
  job.type                    # job type from BPMN (String)
  job.process_instance_key    # workflow instance this job belongs to (Integer)
  job.bpmn_process_id         # BPMN process ID (String)
  job.retries                 # remaining retry attempts (Integer)
  job.deadline                # lock expiration time (frozen Time, UTC)

  # Data (delegated, but declared inputs are preferred — see Declaring Inputs)
  job.variables               # all process variables, as a frozen hash with indifferent access
  job.headers                 # custom headers from BPMN definition, same format

  # Lifecycle (delegated — see Manual Lifecycle Control)
  job.complete!(vars = {})    # mark job complete, with optional output variables
  job.fail!(error, retries: nil, backoff: nil)  # mark job failed
  job.throw_bpmn_error!(code, message = "")     # throw a BPMN error
  job.update_retries(count)   # change remaining retry count
  job.update_timeout(duration)  # extend or shorten the job lock deadline

  # Status predicates (job-only)
  job.ready?                  # true if not yet completed/failed/errored
  job.complete?               # true if completed
  job.failed?                 # true if failed
  job.error?                  # true if BPMN error was thrown
end
```

Worth knowing about how `status` relates to `result` and `error`: `result` and `error` are worker-side records of what came out of executing the job — captured the moment your `perform` decides them. `status` is the engine's ledger as reflected on this worker, and advances only after the relevant GRPC call (`complete_job`, `fail_job`, or `throw_bpmn_error`) succeeds. In normal operation the two views agree, but transient GRPC failures can produce divergence (e.g., a `:failed` worker-side status while the engine has the job in an incident); the worker doesn't observe engine state directly. A naming bridge that helps when cross-referencing Zeebe docs or Operate: Busybee's `:ready` is the worker-side name for what Zeebe calls the **ACTIVATED** state.

Variables and headers support both hash-style and method-style access, including nested values:

```ruby
job.variables[:order_id]          # hash access with symbol key
job.variables["order_id"]         # hash access with string key
job.variables.order_id            # method access
job.variables.address.zip_code    # nested method access
```

Most of the time, you won't need to reach for `job` directly — input accessors give you named, validated methods for reading data, and the lifecycle delegations (`complete!`, `fail!`, etc.) read more naturally without the `job.` prefix. But the job object is there when you need metadata, status checks, or raw data access.

### Declaring Inputs

Inputs declare the data your worker needs from the running workflow instance. Each input becomes an accessor method on your worker, so you can use it directly in `perform` instead of digging through raw hashes.

Inputs come from two sources: **variables** and **headers**. [Variables](https://docs.camunda.io/docs/components/concepts/variables/) are data specific to a running workflow instance: an order ID, a customer email, a calculated total. [Headers](https://docs.camunda.io/docs/components/modeler/bpmn/service-tasks/#task-headers) are set in the BPMN process definition and are the same for every instance, so they are useful for configuration like which email template to send.

#### From Variables

```ruby
class ShipOrderWorker < Busybee::Worker
  variable :order_id, type: :uuid, description: "Order to ship"
  variable :shipping_method, default: "standard"

  def perform
    order = Order.find(order_id)
    order.ship!(method: shipping_method)  # "standard" if not in variables

    { tracking_number: order.tracking_number }
  end
end
```

#### From Headers

```ruby
class CalculateDistanceWorker < Busybee::Worker
  variable :from_lat, type: :decimal
  variable :from_lon, type: :decimal
  variable :to_lat,   type: :decimal
  variable :to_lon,   type: :decimal

  header :algorithm, type: :string, description: "Distance formula to use"

  output :distance, type: :decimal

  def perform
    dist = compute_distance(algorithm)

    { distance: dist.round(3) }
  end
end
```

Because the algorithm is a header, different BPMN tasks can reuse the same worker with different algorithms: one task might set the header to `"haversine"`, another to `"pythagorean"`.

#### From Either Source

Sometimes a value should come from a variable when available, but fall back to a header as a default (or vice versa). Pass an array of sources -- the first non-nil value wins:

```ruby
input :priority, source: [:variable, :header], type: :string
```

This is the general form. The `variable` and `header` DSL methods are shorthands:

```ruby
variable :template                             # same as `input :template, source: :variable`
header :template                               # same as `input :template, source: :header`
input :template, source: [:variable, :header]  # check variable first, then header
```

#### Input Options

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `source:` | Symbol or Array | (required for `input`) | `:variable`, `:header`, or `[:variable, :header]` |
| `required:` | Boolean | `true`\* | Raise `MissingInput` if absent. Cannot combine with `default:` |
| `type:` | Symbol | `nil` | Documentation hint. See [Input/Output Types](#inputoutput-types) |
| `description:` | String | `nil` | Human-readable description |
| `default:` | any | (none) | Default value when input is missing. Makes the input not required |
| `accessor_name:` | Symbol | (same as name) | Custom method name for the accessor |
| `define_accessor:` | Boolean | `true` | Set to `false` to skip accessor definition |

When an input is `required: true` (the default) and the value is missing from the job, Busybee raises `Busybee::MissingInput` before your `perform` method runs. This can alert you to a workflow which is trying to use this worker in an invalid or incorrect way before that might cause harder-to-catch bugs further downstream.

> \* The default value of `required` can be switched for your entire app if desired, allowing you to disable the raise-on-missing behavior. See the [configuration](./configuration.md) document.

### Declaring Outputs

Outputs declare the variables your worker returns to the workflow engine. When your `perform` method returns a Hash, Busybee sends those key-value pairs back as new or updated [process variables](https://docs.camunda.io/docs/components/concepts/variables/):

```ruby
class CreateShipmentWorker < Busybee::Worker
  variable :order_id, type: :uuid
  variable :warehouse_id, type: :uuid

  output :shipment_id, type: :uuid, description: "Created shipment's ID"
  output :item_count, type: :integer, description: "Total item count"

  def perform
    shipment = Shipment.create!(order_id: order_id, warehouse_id: warehouse_id)

    { shipment_id: shipment.id, item_count: shipment.items.count }
  end
end
```

If a required output is missing from the returned Hash, Busybee raises `Busybee::MissingOutput`. This can alert you to a worker which isn't fulfilling its entire contract (isn't doing everything a workflow is relying on it to do).

Note that if `perform` returns nothing at all (or returns anything other than a Hash), no variables are sent back. This is equivalent to returning an empty Hash.

#### Output Options

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `required:` | Boolean | `true`\* | Raise `MissingOutput` if absent from return value |
| `type:` | Symbol | `nil` | Documentation hint |
| `description:` | String | `nil` | Human-readable description |

> \* The default value of `required` can be switched for your entire app if desired, allowing you to disable the raise-on-missing behavior. See the [configuration](./configuration.md) document.

### Input/Output Types

The `type:` option is a documentation hint that describes what kind of value to expect. Types are not enforced at runtime (job variables arrive as JSON and are deserialized accordingly) but they serve as a contract between the BPMN process definition and your worker code. The available types are designed to align well with [JSON](https://www.json.org/) and Zeebe's [FEEL expression language](https://docs.camunda.io/docs/components/modeler/feel/what-is-feel/):

| Type | JSON Representation | Example |
|------|--------------------| --------|
| `string` | String | `"hello"` |
| `integer` | Number (integer) | `42` |
| `decimal` | Number (float) | `99.95` |
| `boolean` | Boolean | `true` |
| `datetime` | String ([ISO 8601](https://en.wikipedia.org/wiki/ISO_8601)) | `"2026-03-06T14:30:00Z"` |
| `duration` | String ([ISO 8601 duration](https://en.wikipedia.org/wiki/ISO_8601#Durations)) | `"PT6H"` |
| `uuid` | String | `"550e8400-e29b-41d4-a716-446655440000"` |
| `null` | null | `null` |

Note that, while JSON and FEEL support array and object types, this version of busybee does not yet provide that support. If you have array- or object-shaped inputs or outputs, either omit the `type:` option, or set it to `null` (which will not be enforced anywhere).

> Worker lifecycle hooks receive these declarations at runtime: each `on_worker_*` hook's `Busybee::Worker::Status` exposes `inputs`, `outputs`, and `description`, so you can register worker metadata in your own tracking / auditing systems. See [Hooks](hooks.md#worker-hooks).

### Advanced DSL Options

#### `complete_job_on_success`

Controls whether Busybee automatically completes the job when `perform` returns without raising. Default: `true`.

Set to `false` when your worker needs to manage the job lifecycle manually (for example, when completion depends on a conditional branch, or when using async patterns):

```ruby
class PickAndPackWorker < Busybee::Worker
  complete_job_on_success false
  fail_job_on_error false

  def perform
    delay = calculate_delay

    Concurrent::Promises.future { simulate_packing(job, delay) }
      .then { complete! }
      .rescue { |err| fail!(err) }
  end
end
```

> See the [Dropship Co. demo app's simulation workers](../spec/demo/app/workers/sim/) for a full example of this pattern.

#### `fail_job_on_error`

Controls whether Busybee automatically fails the job when `perform` raises an exception. Default: `true`.

Set to `false` when you want to handle all errors yourself. Note that if the job is neither completed nor failed, it will eventually time out and be retried by the workflow engine.

#### `description`

A human-readable description of what the worker does. Used for documentation, and exposed to [worker lifecycle hooks](hooks.md#worker-hooks) via `Worker::Status#description`:

```ruby
description "Calculates distance between two geographic points using a configurable algorithm"
```

Not to be confused with the `description:` option on input and output declarations, which is similarly used for documentation.

#### `job_timeout`

How long this worker is allowed to hold a job before the workflow engine assumes that the worker has crashed and will make the job available to another worker. Accepts an Integer (milliseconds) or `ActiveSupport::Duration`:

```ruby
job_timeout 120_000    # 2 minutes
job_timeout 2.minutes  # same, with ActiveSupport
```

Default: `60_000` ms (1 minute), configurable via [`Busybee.default_job_lock_timeout`](configuration.md).

#### `backoff`

How long the workflow engine should wait before making a failed job available for retry. Accepts an Integer (milliseconds) or `ActiveSupport::Duration`:

```ruby
backoff 30_000     # 30 seconds
backoff 30.seconds # same, with ActiveSupport
```

Default: `5_000` ms (5 seconds), configurable via [`Busybee.default_fail_job_backoff`](configuration.md).

#### Mode Configuration in the DSL

Workers can declare their preferred worker mode and any mode-specific options. These serve as defaults that can be overridden at deploy time via CLI flags or YAML configuration (see [Configuration Precedence](#configuration-precedence)):

```ruby
class HighThroughputWorker < Busybee::Worker
  worker_mode :streaming
  streaming buffer: true, buffer_throttle: 5  # 5ms delay between accepting jobs

  def perform
    # ...
  end
end

class BatchWorker < Busybee::Worker
  worker_mode :polling
  polling max_jobs: 50, request_timeout: 30_000

  def perform
    # ...
  end
end
```

See [Worker Modes](#worker-modes) for what these options mean and when to use each mode.

#### DSL Quick Reference

| DSL Method | Arguments | Default | Description |
|------------|-----------|---------|-------------|
| `job_type` | String | Derived from class name | Job type identifier |
| `description` | String | `nil` | Human-readable description |
| `variable` | name, opts | | Declare a variable input |
| `header` | name, opts | | Declare a header input |
| `input` | name, `source:`, opts | | Declare an input from any source |
| `output` | name, opts | | Declare an output |
| `worker_mode` | Symbol | `:hybrid` | `:polling`, `:streaming`, or `:hybrid` |
| `polling` | `max_jobs:`, `request_timeout:` | `25`, `60_000` | Polling mode options |
| `streaming` | `buffer:`, `buffer_throttle:` | `true`, `false` | Streaming mode options |
| `job_timeout` | Integer or Duration | `60_000` | Job lock timeout (ms) |
| `backoff` | Integer or Duration | `5_000` | Retry backoff delay (ms) |
| `backpressure_delay` | Integer or Duration | `2_000` | Delay after backpressure error (ms) |
| `complete_job_on_success` | Boolean | `true` | Auto-complete on success |
| `fail_job_on_error` | Boolean | `true` | Auto-fail on exception |
| `shutdown_on` | Exception class(es) | `[]` | Exceptions that trigger shutdown |

---

## Running Workers

### CLI Quick Start

Run a worker with `bundle exec busybee`:

```bash
# Run a single worker
bundle exec busybee ProcessOrderWorker

# Run multiple workers in one process
bundle exec busybee ProcessOrderWorker ShipOrderWorker NotifyCustomerWorker

# Run workers defined in a YAML config file
bundle exec busybee --config config/busybee.yml
```

The CLI loads your Rails environment automatically (if present), instantiates the named worker classes, and starts processing jobs. Press Ctrl-C for a graceful shutdown, or Ctrl-C again to force-quit.

If you've used [Racecar](https://github.com/zendesk/racecar) to run Kafka consumers, this pattern should be familiar: one executable, one or more handler classes, and a long-running process that connects to the messaging infrastructure and dispatches work.

### CLI Reference

```
Usage: busybee [options] WorkerClass [WorkerClass ...]
```

| Flag | Short | Type | Description |
|------|-------|------|-------------|
| `--config FILE` | `-c` | String | Path to a [YAML configuration file](#yaml-configuration) |
| `--worker-mode MODE` | `-m` | String | Worker mode: `polling`, `streaming`, or `hybrid` |
| `--log-format FORMAT` | `-l` | String | Log format: `text` or `json` |
| `--worker-name NAME` | `-n` | String | Worker process identifier (default: hostname) |
| `--cluster-address ADDR` | `-a` | String | Zeebe gateway address as `host:port` |
| `--version` | `-v` | | Print version and exit |
| `--help` | `-h` | | Print help and exit |

**Mutual Exclusions:**

- `--config` and `--worker-mode` cannot be used together. Set `worker_mode` in YAML instead.
- `--config` and positional worker arguments cannot be used together. List workers in YAML instead.

### Rails Integration

The CLI automatically loads your Rails environment by requiring `./config/environment`. This means your workers have access to your models, application config, and everything else in your Rails app. Most gem configuration settings (credentials, logging, etc.) can be set through Rails app configuration values. See [Configuration: Rails Integration](configuration.md#rails-integration).

If you don't have Rails installed, loading the environment will be skipped automatically and transparently. If you _do_ have Rails installed but for some reason you want to skip loading the Rails environment, you can set an env var:

```bash
BUSYBEE_SKIP_RAILS=1 bundle exec busybee MyWorker
```

(Using an env var is necessary because the decision to attempt loading the environment must be made before we could load any configuration values from that environment.)

### Signal Handling

The worker process responds to standard Unix signals:

| Signal | First time | Second time |
|--------|-----------|------------|
| `INT` (Ctrl-C) | Graceful shutdown: stop accepting new jobs, finish in-flight work | Force shutdown: exit immediately |
| `TERM` | Same as INT | Same as INT |
| `QUIT` | Same as INT | Same as INT |

During graceful shutdown, any jobs that were received from the workflow engine but not yet started are failed back to the workflow engine with their retry count preserved, so they'll be picked up by another worker.

### Worker Modes

Zeebe supports two different ways of fetching jobs for your worker: long-polling or streaming. Both of them have advantages and disadvantages. Busybee supports both modes, as well as a third hybrid mode which eliminates the downsides of using either polling or streaming alone.

**If you don't know (or don't want to think about) which mode to use, use hybrid mode.** It's the default, it's been specifically designed to give you the best of both worlds, and it will allow you to mostly ignore this section. However, if you want to understand the tradeoffs between the different modes, read on.

#### Polling

```ruby
worker_mode :polling
```

In polling mode, the busybee process for your worker repeatedly [long-polls](https://docs.camunda.io/docs/apis-tools/zeebe-api/gateway-service/#activatejobs-rpc) the Zeebe gateway: "give me up to N jobs of this type." If no jobs are available, the call blocks until at least one job is available. Your worker receives the available jobs, processes them sequentially, then polls again.

This is the simplest mode, built on the oldest API. It has two principal downsides compared to streaming mode: one, it requires considerably more network traffic, and two, it results in additional latency for each job (both within the workflow engine, while buffering waiting for a polling request, and in the worker process while the batch is being sequentially processed). However, it avoids the main downside of [streaming mode](#streaming) by guaranteeing that it will eventually retrieve all jobs created prior to the polling request.

**Options:**

| Option | DSL | YAML/CLI | Default | Description |
|--------|-----|----------|---------|-------------|
| Max jobs per request | `polling max_jobs: N` | `max_jobs` | `25` | Limit on how many jobs to fetch per poll |
| Request timeout | `polling request_timeout: N` | `request_timeout` | `60_000` ms | Limit on how long to wait for jobs before the gateway returns an empty response |

**When to Use:** Polling is good for local prototyping, to ensure that backlogs of unprocessed "invisible" jobs cannot form due to race conditions. For deployed or production-like environments, polling should not normally be used, but could be useful during incident response to help clean up a large backlog of available jobs.

#### Streaming

```ruby
worker_mode :streaming
```

In streaming mode, the busybee process for your worker opens a persistent [gRPC stream](https://docs.camunda.io/docs/apis-tools/zeebe-api/gateway-service/#streamactivatedjobs-rpc) connection to the workflow engine. The engine pushes jobs to your worker as soon as they're created.

This is the more modern mode, giving you the lowest possible latency for new jobs, and the lowest amount of network overhead to get them. But it has a major downside: streams only ever deliver jobs *created after the stream opens.* If there were jobs of that type already backlogged in the workflow engine, a worker in streaming mode won't ever see them. For that, you need polling or [hybrid mode](#hybrid).

With default settings, a streaming worker accepts jobs from the workflow engine immediately, buffering them in memory in ruby prior to actual execution by your worker code. This helps ensure the stream stays responsive and enables [buffer throttling](#buffer-throttle) for controllable backpressure if the size of the in-memory buffer becomes too large. Jobs are still processed sequentially.

**Options:**

| Option | DSL | YAML/CLI | Default | Description |
|--------|-----|----------|---------|-------------|
| Buffer mode | `streaming buffer: true/false` | `buffer` | `true` | Use the buffer. Set to `false` for inline (unbuffered) processing. |
| Buffer throttle | `streaming buffer_throttle: N` | `buffer_throttle` | `false` | Delay between accepting jobs, in ms. See [Buffer Throttle](#buffer-throttle). |

**When to Use:** Whenever you can guarantee that there will be no pre-existing backlog of available jobs. In practice, that guarantee can be difficult to meet, because it depends on human processes to ensure that workflows are never deployed or started before all of the workers they rely on are already running.

#### Hybrid

```ruby
worker_mode :hybrid
```

In hybrid mode, busybee combines both approaches to avoid the downsides of either. It opens a stream to capture new jobs immediately, buffering them in memory, then also makes polling requests to drain any backlog. Once the backlog is caught up, it stops polling and continues stream-only processing.

This is the default mode, and it should be set-and-forget in most cases.

Hybrid mode works in three phases:

1. **Open Stream** - starts receiving new jobs immediately, into the buffer.
2. **Drain Backlog** - polls for pre-existing jobs while also processing any stream jobs that arrive. Stream jobs always take priority (the backlog is only drained if the worker is keeping ahead of the new jobs in the stream).
3. **Stream Only** - once the backlog is caught up, it stops polling, but continues processing jobs from the stream.

All calls to your `perform` method happen on the main thread, maintaining the same sequential guarantee as the other modes.

**When to use:** Nearly always. This is the default and the right choice for most workloads. You get low latency for new jobs, low network load, *and* reliable backlog processing after deploys or restarts.

#### Buffer Throttle

When using hybrid mode, or streaming mode with the default `buffer: true`, jobs are consumed from the gRPC stream as soon as they are available, and are buffered in memory while they wait for your worker to process them. This design avoids applying any [backpressure](https://docs.camunda.io/docs/components/concepts/job-workers/#backpressure) to the gRPC gateway, so that the stream does not get marked as `not-ready` and end up missing future jobs (see that link for details).

For most workloads, this arrangement should work smoothly. But if your worker processes jobs slowly while the workflow engine is pushing lots of jobs fast, then the buffer (and ruby heap size) can start to grow without bound.

The `buffer_throttle` option lets you address this situation by adding a sleep between accepting each job. This limits the rate at which busybee accepts jobs from the gRPC gateway, which limits how fast the buffer can grow.

For most users, the default (false, no throttle) should be correct most of the time. Only tune this if you observe concerning memory growth or OOM errors from your workers due to unbounded buffer depth.

```ruby
streaming buffer: true, buffer_throttle: 5.0  # 5ms delay between accepting each job -- max 200 jobs/s
```

| `buffer_throttle` value | Behavior | Rate Cap (Appx.) |
|-------------------------|----------|------------------|
| `false` (default) | No throttling (buffer can grow without bound) | Not capped |
| `0` | Minimal possible throttling (see Sleep Granularity, below) | ~200k - ~1M jobs/sec |
| `0.1` - `10` (ms) | Practical range for stable throttling | Up to 10,000 jobs/sec |

Note that `buffer_throttle` is not a panacea. If your system is generating jobs at a faster rate than your worker can process them, enabling throttling **alone** will only make the problem worse. If the stream for your worker is [marked `not-ready` by the gRPC gateway due to being too slow](https://docs.camunda.io/docs/components/concepts/job-workers/#backpressure), some future jobs will not be routed to it and will end up "hidden" in the workflow engine's buffer, where they will never be sent to a stream (and must be polled for). The _true_ solution to the problem of having too many jobs is to add additional capacity by scaling your worker either horizontally (adding more replicas) or vertically (adding more CPU or memory). In such a situation, using `buffer_throttle` lets you ensure that any one replica never gets overloaded and runs out of memory.

> Worker-lifecycle hooks (`on_worker_*`) surface live buffer depth for exactly this: each receives a `Busybee::Worker::Status` carrying `current_buffer_size` and `peak_buffer_size`, so you can monitor buffer growth and detect when a worker needs additional capacity. The same `Worker::Status` is also stamped onto each job (`job.worker_status`) at activation and execution, so job hooks can sample buffer depth *continuously* as work flows, rather than only at the four worker-lifecycle moments. See [Hooks](hooks.md#worker-hooks).

**Sleep Granularity:** Ruby's `Kernel#sleep` delegates to `nanosleep(2)` on POSIX systems. Values down to 0.1ms (100 microseconds) work reliably on modern Linux and macOS. Below that, OS scheduler and GVL overhead dominate, so sub-0.1ms values are unlikely to behave meaningfully. Therefore, the maximum *stable and reliable* rate cap you can get is close to 10k jobs/sec, which you get from `buffer_throttle: 0.1`.

However, there is an option that gives you a rate cap higher than this value without being totally unthrottled. If you set `buffer_throttle` to 0, the thread does not actually sleep, but it does cause a context swap, which slows it down more than simply doing nothing (on the order of 1-5µs). Setting `buffer_throttle: 0` should give you a rate cap somewhere between roughly 200k - 1M jobs/sec, but the exact value will depend on your infrastructure.

#### Backpressure

When the Zeebe cluster is under heavy load, it may respond to requests with a `ResourceExhausted` GRPC error. Both the polling and hybrid modes handle this automatically by sleeping for `backpressure_delay` milliseconds (default: 2,000) before retrying.

```ruby
backpressure_delay 10_000  # wait 10 seconds on backpressure
```

> Backpressure delays are slated to be overhauled in v0.5, and this section is expected to be rewritten at that time.

### Multiple Workers in One Process

When you pass multiple worker classes (via CLI args or YAML), Busybee runs them in a single process. Each worker runs in a dedicated thread, sharing a single gRPC connection to Zeebe:

```bash
bundle exec busybee ProcessOrderWorker ShipOrderWorker NotifyCustomerWorker
```

Each worker's configuration gets resolved independently through the [precedence chain](#configuration-precedence), so one worker can poll while another worker streams.

#### Thread Safety

Jobs of the *same* type are always processed sequentially. That is, only one instance of a given worker class will ever be executing `perform` at a given moment. But jobs of *different* types in the same container will run in parallel across threads. If your workers perform operations on shared resources (global state, shared caches, non-thread-safe libraries), you'll need to handle synchronization yourself. Most common Rails operations (ActiveRecord queries, cache reads/writes) are already thread-safe.

> An opt-in feature to run workers concurrently (multi-threaded) will be included in a future version of Busybee, and this section will be updated.

#### Database Connections

When running multiple workers, ensure your database connection pool is large enough to support one connection for each worker. Busybee logs a warning at startup if the ActiveRecord pool size is smaller than the number of workers.

### YAML Configuration

For repeatable deployments, define your worker configuration in a YAML file:

```yaml
# config/busybee.yml
worker_mode: hybrid
job_timeout: 120000
backoff: 10000

workers:
  - ProcessOrderWorker
  - ShipOrderWorker
  - NotifyCustomerWorker
```

Run it with:

```bash
bundle exec busybee --config config/busybee.yml
```

#### Per-Worker Overrides

Different workers often have different performance characteristics, so YAML supports per-worker overrides for any per-worker setting:

```yaml
worker_mode: hybrid
workers:
  - ProcessOrderWorker:
      worker_mode: polling
      max_jobs: 50
      request_timeout: 10000
  - ShipOrderWorker:
      worker_mode: streaming
      buffer_throttle: 5
  - NotifyCustomerWorker  # uses top-level defaults
```

#### YAML Reference

**Top-level keys** (apply to all workers unless overridden):

| Key | Type | Description |
|-----|------|-------------|
| `worker_mode` | String | `polling`, `streaming`, or `hybrid` |
| `max_jobs` | Integer | Max jobs per polling request |
| `request_timeout` | Integer | Long-poll timeout (ms) |
| `job_timeout` | Integer | Job lock timeout (ms) |
| `backoff` | Integer | Retry backoff (ms) |
| `backpressure_delay` | Integer | Delay after backpressure error (ms) |
| `buffer` | Boolean | Enable job buffering in streaming mode |
| `buffer_throttle` | Integer/Boolean | Job buffer delay (ms). `false` to disable |
| `workers` | Array | Worker class names, with optional per-worker overrides |

**Process-wide settings** (`log_format`, `worker_name`, `cluster_address`) are CLI-only and cannot be set in YAML. Use the corresponding CLI flags alongside `--config`:

```bash
bundle exec busybee --config config/busybee.yml --log-format json --worker-name "prod-worker-1"
```

> For a realistic example, see the [Dropship Co. demo app's busybee config files](../spec/demo/config/busybee/).

### Configuration Precedence

**Worker runtime settings** resolve through a 4-level precedence chain. Each level overrides the one below it:

```
Per-Worker Override in YAML    (highest priority)   `workers: - MyWorker: { max_jobs: 50 }`
     |                                 v
Top-Level YAML / CLI Flag              v            `max_jobs: 50` (at YAML top level)
     |                                 v
Worker DSL Declaration                 v            `polling max_jobs: 32` (in the Worker class)
     |                                 v
Gem Configuration & Defaults   (lowest priority)    `Busybee.default_max_jobs` (25 by default, but can be set in config)
```

The first non-nil value wins. This means `0` and `false` are valid explicit values -- for example, `buffer_throttle: false` explicitly disables throttling even if a lower level sets it.

The [per-worker settings](#yaml-reference) this applies to are: `worker_mode`, `max_jobs`, `request_timeout`, `job_timeout`, `backoff`, `backpressure_delay`, `buffer`, and `buffer_throttle`.

**Process-wide settings** (like `--log-format`, `--worker-name`, and `--cluster-address`) follow a simpler 2-level chain: the CLI flag, then gem config / default. They don't participate in per-worker overrides because they always apply to the entire process. Also, they often take env vars as their inputs, so they are less useful in YAML.

For gem-level defaults (the bottom of the chain), see [Configuration](configuration.md).

---

## Testing Workers

Busybee includes helpers that let you unit test your workers without a running Zeebe instance, by constructing a simulated job and then running the real worker lifecycle with it.

This is a complement to the [workflow tests](testing.md) that you write. Those verify your process definitions, ensuring that the correct jobs will be available with the correct variables at the right times in the business process. These, by contrast, verify that your workers perform those jobs correctly under different conditions and with different inputs.

See that link for information about testing the workflow definitions. Read on for more about testing your workers.

### Setup

If you've already set up `busybee/testing` for BPMN workflow tests, worker testing helpers are available automatically. If not:

```ruby
# spec/spec_helper.rb or spec/rails_helper.rb
require "rspec"
require "busybee/testing"
```

This makes `execute_worker`, `build_test_job`, and the worker matchers available in all RSpec examples.

### Basic Worker Testing

The simplest way to test a worker is `execute_worker`. It runs the full worker lifecycle (input validation, `perform`, output validation, auto-complete) and returns the result:

```ruby
RSpec.describe ProcessOrderWorker do
  let(:order) { create(:order) }

  it "processes the order and returns confirmation number" do
    result = execute_worker(described_class, variables: { order_id: order.id })
    expect(result[:confirmation_number]).to be_present
  end

  it "marks the order as processed" do
    execute_worker(described_class, variables: { order_id: order.id })
    expect(order.reload).to be_processed
  end

  it "raises when order is missing" do
    expect {
      execute_worker(described_class, variables: { order_id: "nonexistent" })
    }.to raise_error(ActiveRecord::RecordNotFound)
  end
end
```

`execute_worker` accepts the same keyword arguments as `build_test_job`:

| Argument | Type | Default | Description |
|----------|------|---------|-------------|
| `variables:` | Hash | `{}` | Process variables |
| `headers:` | Hash | `{}` | Custom headers |
| `bpmn_process_id:` | String | `"test-process"` | BPMN process ID |
| `retries:` | Integer | `3` | Retry count |

Errors are re-raised after the worker's error handling runs, so you can use `expect { }.to raise_error` alongside job status assertions (see below).

### Inspecting Job State

When you need to assert on what the worker *did* to the job (completed it? failed it? threw a BPMN error?), or if you need so many variables or headers that passing all options inline becomes unreadable, you can build a test job first with `build_test_job` and then pass it to `execute_worker`:

```ruby
RSpec.describe ProcessOrderWorker do
  it "completes the job on success" do
    job = build_test_job(variables: { order_id: create(:order).id })
    execute_worker(described_class, job: job)
    expect(job).to be_complete
  end

  it "fails the job on error" do
    job = build_test_job(variables: { order_id: "nonexistent" })
    expect { execute_worker(described_class, job: job) }
      .to raise_error(ActiveRecord::RecordNotFound)
    expect(job).to be_failed
  end
end
```

`build_test_job` returns a real `Busybee::Job` backed by a stub client. All lifecycle operations (`complete!`, `fail!`, `throw_bpmn_error!`) update the job's status but don't make any network calls.

### Worker Testing Matchers

For more expressive assertions, Busybee provides three RSpec matchers that combine execution and verification in a single expectation.

#### `complete_job`

Asserts that a worker completes the job successfully:

```ruby
job = build_test_job(variables: { order_id: order.id })

# Just assert completion
expect(ProcessOrderWorker).to complete_job(job)

# Assert completion with specific output variables
expect(ProcessOrderWorker).to complete_job(job)
  .with_vars(confirmation_number: "ORD-123")

# Assert completion with no output variables
expect(NotifyCustomerWorker).to complete_job(job).with_no_vars

# Works with RSpec composable matchers
expect(ProcessOrderWorker).to complete_job(job)
  .with_vars(hash_including(confirmation_number: a_string_starting_with("ORD-")))
```

#### `fail_job`

Asserts that a worker fails the job. Optionally match the error class and/or message, using the same argument forms as RSpec's `raise_error`:

```ruby
job = build_test_job(variables: { order_id: "nonexistent" })

# Just assert failure
expect(ProcessOrderWorker).to fail_job(job)

# Match error class
expect(ProcessOrderWorker).to fail_job(job)
  .with_error(ActiveRecord::RecordNotFound)

# Match error class and message pattern
expect(ProcessOrderWorker).to fail_job(job)
  .with_error(ActiveRecord::RecordNotFound, /Couldn't find Order/)

# Match message only
expect(ProcessOrderWorker).to fail_job(job)
  .with_error(/not found/)
```

#### `throw_bpmn_error_on`

Asserts that a worker throws a [BPMN error](https://docs.camunda.io/docs/components/modeler/bpmn/error-events/). Remember, BPMN errors are a workflow control-flow concept, distinct from a Ruby exception. When your worker throws a BPMN error, it signals to the process instance that a known business condition occurred, and the workflow definition decides what happens next.

```ruby
job = build_test_job(variables: { order_id: expired_order.id })

# Just assert a BPMN error was thrown
expect(ProcessOrderWorker).to throw_bpmn_error_on(job)

# Match error code (symbol form - converted to uppercase)
expect(ProcessOrderWorker).to throw_bpmn_error_on(job)
  .with_code(:order_expired)  # matches code "ORDER_EXPIRED"

# Match error code and message
expect(ProcessOrderWorker).to throw_bpmn_error_on(job)
  .with_code(:order_expired, message: /has expired/)

# Match code from exception class (MyApp::OrderExpired -> "MY_APP_ORDER_EXPIRED")
expect(ProcessOrderWorker).to throw_bpmn_error_on(job)
  .with_code(MyApp::OrderExpired)
```

### Testing Best Practices

One recommended pattern is to compose `build_test_job` using RSpec's `let` blocks, then reuse the job in different contexts while adjusting / overriding the individual parameters. Provided that the `let` blocks themselves do not become unwieldy, this can be a powerful and elegant pattern:

```ruby
describe ProcessOrderWorker do
  # There could potentially be many more variables, and/or some headers, but we show just one for clarity:
  let(:job) { build_test_job(variables: variables) }
  let(:variables) { { order_id: order_id } }

  let(:order) { create :order } # e.g. FactoryBot or similar fixture setup
  let(:order_id) { order.id }

  context "with a valid order" do
    it "processes the order normally" do
      expect(described_class).to complete_job(job).with_vars(confirmation_number: /[A-Z]{6}/)
    end
  end

  # Now we can override just the fixture object while reusing the rest of the job setup:
  context "with an order without sufficient funds" do
    let(:order) { create :order, :insufficient_funds } # e.g. a FactoryBot trait or similar

    it "throws a BPMN error so the workflow can branch" do
      expect(described_class).to throw_bpmn_error_on(job).with_code("INSUFFICIENT_FUNDS")
    end
  end

  # Or we can override just the variable's value itself, and bypass the fixture entirely:
  context "when the order is not found" do
    let(:order_id) { SecureRandom.uuid }

    it "fails and reports the error" do
      expect(described_class).to fail_job(job).with_error(ActiveRecord::RecordNotFound)
    end
  end

  # Or even override the entire set of variables:
  context "when a workflow does not pass the expected set of variables" do
    let(:variables) { {} }

    it "fails input validation, alerting us to the problem" do
      expect(described_class).to fail_job(job).with_error(Busybee::MissingInput)
    end
  end
end
```

For more realistic examples, see the [demo app's worker specs](../spec/demo/spec/workers/).
