# Hooks

Busybee's hook system lets you attach your own code to the lifecycle moments that matter in a worker process: a job arriving, your `perform` method running, a worker shutting down, a gRPC call going over the wire. Hooks serve two roles:

- **Middleware** — wrapping work with behavior of your own: database transactions around `perform`, tracing spans, tenancy scoping.
- **Observation** — feeding your metrics, logging, and error-reporting systems: Datadog distributions per call, Sentry reports per failed job, a worker-liveness dashboard.

You register hooks once at boot, typically in the same `Busybee.configure` block as the rest of your configuration. Each hook receives a single rich carrier object for its subject, and optional filters let a hook fire only for the slice of traffic it cares about.

> For a working example of a full observability integration built on hooks, see the [Dropship Co. demo app](../spec/demo/README.md) — its monitoring UI is fed entirely by the hooks described here.

## Table of Contents

- [Hooks at a Glance](#hooks-at-a-glance)
- [The Three Subjects](#the-three-subjects)
- [Metrics and Logs: The Two Projections](#metrics-and-logs-the-two-projections)
- [Registering Hooks](#registering-hooks)
- [Filtering](#filtering)
  - [Filter Keys by Subject](#filter-keys-by-subject)
  - [How Filters Match](#how-filters-match)
  - [Matching on Errors](#matching-on-errors)
- [Job Hooks](#job-hooks)
  - [Two Lifecycles, One Naming Rule](#two-lifecycles-one-naming-rule)
  - [Wrapping perform: Middleware](#wrapping-perform-middleware)
  - [Watching the System Lifecycle](#watching-the-system-lifecycle)
  - [Reading the Job](#reading-the-job)
- [Worker Hooks](#worker-hooks)
  - [The Four Moments](#the-four-moments)
  - [Reading Worker::Status](#reading-workerstatus)
  - [Stop Reasons](#stop-reasons)
- [Call Hooks](#call-hooks)
  - [Reading the Call](#reading-the-call)
  - [Fetching Is Observed at Dispatch](#fetching-is-observed-at-dispatch)
- [When Hooks Raise](#when-hooks-raise)
- [Hooks and Threads: Own What You Spawn](#hooks-and-threads-own-what-you-spawn)
- [Observing Deferred Resolutions](#observing-deferred-resolutions)
- [Test Isolation](#test-isolation)

---

## Hooks at a Glance

```ruby
# config/initializers/busybee.rb (or anywhere during app boot)
Busybee.configure do |config|
  # Middleware: wrap every perform in a database transaction
  config.around_perform do |job, perform|
    ApplicationRecord.transaction { perform.call }
  end

  # Observation: report failed jobs, with full structured context
  config.after_perform(status: :failed) do |job|
    Sentry.capture_exception(job.error, extra: job.logging_context)
  end

  # Observation: time every gRPC call to the workflow engine
  config.after_call do |call|
    StatsD.distribution("zeebe.call_ms", call.network_ms, tags: call.context_tags)
  end

  # Observation: know why each worker process stopped
  config.on_worker_shutdown do |worker|
    Rails.logger.info("[workers] #{worker.worker_name} stopped: #{worker.reason}")
  end
end
```

Hooks run synchronously, on the thread doing the work they're attached to. Keep them fast; if a hook needs to do something slow (network writes, disk flushes), hand the work to a thread or executor you own — and read [Hooks and Threads](#hooks-and-threads-own-what-you-spawn) before you do.

## The Three Subjects

Hooks attach to three subjects, and every hook receives its subject's **carrier** — one object holding everything there is to know at that moment:

| Subject | Hooks | Carrier | Character |
|---------|-------|---------|-----------|
| **Job** | `before_perform`, `around_perform`, `after_perform`, `on_job_activated`, `around_job_execution`, `on_job_executed` | `Busybee::Job` — the live job object | Middleware + observation |
| **Worker** | `on_worker_started`, `on_worker_stop_requested`, `on_worker_stopping`, `on_worker_shutdown` | `Busybee::Worker::Status` — a frozen snapshot | Observation only |
| **Call** | `before_call`, `around_call`, `after_call` | `Busybee::Client::Call` — a per-operation record | Observation, plus a gate before the call |

The contrast between the **live Job** and the **frozen Worker::Status** is deliberate. Job hooks are a control seam: middleware is *supposed* to participate — wrap `perform` in a transaction, annotate the job's context, let an error propagate to fail the job. Worker hooks are pure observation: the snapshot carries no `stop!`/`kill!` controls and is frozen, so a hook cannot steer the runner from inside an observation. Each firing gets a fresh snapshot; a `nil` reader means "not known yet" (for example, `reason` before the run ends).

## Metrics and Logs: The Two Projections

All three carriers expose the same pair of projections, so one observation pattern works everywhere:

- **`context_tags`** — a low-cardinality Hash, safe to use as **metric labels**. Identity and outcome only: job type, worker class, status, error class name. Nothing unbounded.
- **`logging_context`** — a high-cardinality superset of `context_tags`, meant for **structured log fields**: keys, timestamps, durations, counters, error messages.

```ruby
config.on_job_executed do |job|
  StatsD.increment("jobs.executed", tags: job.context_tags)          # bounded label set
  Rails.logger.info("job executed #{job.logging_context.to_json}")   # the full picture
end
```

The split exists because metrics systems price by label cardinality while log systems don't: send `logging_context` to a metrics backend and you'll blow out its index; send only `context_tags` to your logs and you'll wish you had the job key. Every key in `context_tags` also appears in `logging_context` with the same value.

## Registering Hooks

Every hook type is a method on the configuration surface: pass filters as keyword arguments, and the hook body as a block. The block receives the carrier.

```ruby
Busybee.configure do |config|
  config.before_perform { |job| ... }
  config.around_perform(job_type: "charge_card") { |job, perform| ... }
  config.after_call(rpc: :publish_message) { |call| ... }
end
```

Things worth knowing:

- **Register at boot.** Hooks are meant to be registered while your app boots (a Rails initializer is the natural home) and left alone; there is no supported way to add or remove hooks while workers are running.
- **Multiple hooks per type are fine** and run in registration order. An `around_*` chain nests: the first-registered hook is outermost.
- **Hooks are global, filters give them scope.** All workers in a process share one hook registry; use `worker_class:`/`job_type:` filters to scope a hook to particular workers.
- **Registration fails loudly.** An unknown hook name, an unknown filter key for that subject, or a nonsense `error:` matcher raises `ArgumentError` at boot — not silently at fire time.

## Filtering

Filters decide whether a registered hook fires for a given event. A hook with no filters always fires. A hook with several filters fires only when **all** of them match.

```ruby
# Only failed jobs of one type
config.after_perform(job_type: "charge_card", status: :failed) { |job| ... }

# Any signal-driven worker stop
config.on_worker_shutdown(reason: /\Asig/) { |worker| ... }

# Backpressure responses from the engine
config.after_call(grpc_status: :resource_exhausted) { |call| ... }
```

### Filter Keys by Subject

Each filter key reads the same-named attribute off the carrier:

| Subject | Filter keys |
|---------|-------------|
| Job | `job_type:`, `worker_class:`, `status:`, `bpmn_process_id:`, `source:`, `buffered:`, `error:` |
| Worker | `worker_class:`, `job_type:`, `worker_mode:`, `reason:`, `error:` |
| Call | `rpc:`, `status:`, `grpc_status:`, `error:` |

Useful value vocabularies: job `status:` is `:ready` / `:complete` / `:failed` / `:error`; job `source:` is `:poll` / `:stream`; call `status:` is `:pending` / `:succeeded` / `:errored`; worker `worker_mode:` is `:polling` / `:streaming` / `:hybrid`. For `reason:` see [Stop Reasons](#stop-reasons), and for `rpc:` see [Reading the Call](#reading-the-call).

### How Filters Match

A filter value can be more than a literal:

| Filter value | Matches when |
|--------------|--------------|
| Symbol / String | the attribute equals it |
| Regexp | the attribute matches the pattern (Class attributes match on their name, so `worker_class: /\AOms::/` works) |
| Class | the attribute is an instance of it — or is that class itself (so `worker_class: OrderWorker` works) |
| Proc | `proc.call(value)` is truthy |
| Array | **any** element matches — elements may mix all of the above |
| `nil` | always — `nil` means "don't filter on this key" |

The `nil` rule is there for programmatic composition: `config.on_worker_shutdown(reason: ENV["ONLY_REASON"]&.to_sym) { ... }` degrades to "fire for every reason" when the variable is unset, rather than never firing.

```ruby
# Array: either job type
config.around_perform(job_type: %w[create_shipment update_shipment_status]) { |job, perform| ... }

# Regexp against class names: every worker in one namespace
config.on_job_executed(worker_class: /\ALogistics::/) { |job| ... }

# Proc: anything the other matchers can't say
config.on_job_activated(buffered: ->(b) { b }) { |job| ... }
```

### Matching on Errors

The `error:` filter is available on all three subjects, and it has its own semantics: the filter describes the error — or its absence.

| `error:` value | Matches when |
|----------------|--------------|
| `false` | no error is present |
| `true` | any error is present |
| a Class or Module | `error.is_a?(...)` — inheritance and mixins count, like `rescue` |
| a String | the error's own class name, exactly |
| a Regexp | the error's own class name, by pattern |
| an Array | any element matches (elements may mix kinds; `nil` elements are rejected at registration) |
| a Proc | `proc.call(error)` is truthy |

```ruby
# Any timeout raised by perform, by class hierarchy
config.after_perform(error: Faraday::TimeoutError) { |job| ... }

# Timeouts from any library, by name pattern
config.after_perform(error: /Timeout/) { |job| ... }

# Jobs that finished clean
config.on_job_executed(error: false) { |job| ... }
```

Two details to keep straight:

- **Name matchers don't see ancestry.** `error: "StandardError"` matches only an error whose class is literally named `StandardError`; to match a hierarchy, pass the Class itself. This mirrors `rescue`: hierarchy matching needs the live constant.
- With **no error present**, only `false` matches — every other matcher requires an error to exist (Procs aren't even called).

The carriers also expose an `error_class` *reader* — that one exists for projections (a class name makes a good metric label); filtering always goes through `error:`, matched against the exception itself.

## Job Hooks

### Two Lifecycles, One Naming Rule

A job has two lifecycles, and the hook names tell you which one you're attaching to:

- **`perform` in the name → your code's lifecycle.** `before_perform`, `around_perform`, and `after_perform` are scoped tightly to your worker's `perform` method — the natural home for business-level middleware and outcome reporting.
- **`job` in the name → the system's lifecycle.** `on_job_activated`, `around_job_execution`, and `on_job_executed` follow the job through busybee's machinery — activation, buffering, validation, automatic completion/failure, the response back to the engine.

Here is where each fires, in order:

```text
on_job_activated            # the runner received the job
   (buffer wait, if the job came through a streaming buffer)
around_job_execution ─┐     # the system envelope opens
   input validation   │
   before_perform     │
   around_perform ─┐  │     # your envelope opens
      perform      │  │
   around_perform ─┘  │
   auto-complete / auto-fail
   after_perform      │     # only if the job resolved (see below)
around_job_execution ─┘
on_job_executed             # the runner finished with the job — every exit path
```

| Hook | Fires | Receives |
|------|-------|----------|
| `on_job_activated` | the moment the runner receives the job, before any buffer wait | `job` |
| `around_job_execution` | around the whole system envelope: validation, perform, automatic resolution | `job, perform` |
| `before_perform` | after input validation, just before `perform` | `job` |
| `around_perform` | wrapped immediately around `perform` | `job, perform` |
| `after_perform` | when the perform envelope exits **with a settled outcome** | `job` |
| `on_job_executed` | when the runner finishes with a job it ran — on every exit path ([except a shutdown](#watching-the-system-lifecycle)) | `job` |

**The `after_perform` firing condition is worth reading twice.** It fires only when the job actually resolved — completed, failed, or BPMN-errored, with the engine informed. If automatic failure is disabled, or the resolution gRPC call itself failed, the perform envelope exits *without* a settled outcome, `after_perform` stays silent, and the engine will eventually re-deliver the job. A hook that must observe every exit path belongs on `on_job_executed`.

### Wrapping perform: Middleware

`around_perform` and `around_job_execution` receive `(job, perform)`; calling `perform.call` runs the rest of the chain. Call it exactly once.

```ruby
# A transaction around the business logic only
config.around_perform(job_type: "update_order_status") do |_job, perform|
  Oms::Record.transaction { perform.call }
end

# A tracing span around the whole system envelope, including auto-fail
config.around_job_execution do |job, perform|
  Datadog::Tracing.trace("busybee.job", resource: job.job_type) { perform.call }
end
```

Which of the two you want follows from the naming rule: a transaction belongs around *your code* (`around_perform` — an auto-fail gRPC call has no business inside it), while an APM span usually wants the *whole story* (`around_job_execution` — including validation failures and automatic resolution).

Rules of the middleware road:

- **The return value is safe.** Your worker's result is harvested from the job itself, not from the chain's return value — middleware can't lose it by returning something else.
- **Hooks can't resolve the job.** `complete!`, `fail!`, and `throw_bpmn_error!` are legal only inside `perform`; called from a hook they raise `Busybee::StatusChangeOutsidePerform`. Middleware shapes the *environment* of the work; the work itself decides the outcome.
- **`around_job_execution` is observing.** Errors it raises are logged and swallowed, and if it returns without calling `perform.call`, busybee logs a warning and runs the rest of the chain anyway — an observer can't silently cancel a job. `around_perform` is the propagating one: errors it raises fail the job (see [When Hooks Raise](#when-hooks-raise)).

### Watching the System Lifecycle

`on_job_activated` and `on_job_executed` bracket the job's whole visit to your process, and they're the natural feed for per-job records:

```ruby
config.on_job_activated { |job| Monitoring.job_arrived(job) }
config.on_job_executed  { |job| Monitoring.job_finished(job) }
```

`on_job_activated` fires before any buffer wait, so on a streaming worker the gap between the two is visible as `job.buffer_latency_ms`. `on_job_executed` then fires for every job the worker actually ran, on every exit path — completed, failed, or left unresolved because the resolution call itself failed.

**The bracket doesn't close across a shutdown.** A job that was activated but never ran gets no `on_job_executed`: the drain fails those still in flight, and `kill!` discards whatever is still sitting in the buffer. So a gauge you increment on activation and decrement on execution leaks on every deploy, by however many jobs were in hand when the signal arrived. Reconcile from `on_worker_shutdown` — which does fire on every exit path — rather than relying on the pair.

Whenever a job is buffered — the default on streaming and hybrid workers — the two fire on **different threads**. `on_job_activated` runs on the pump thread pulling jobs off the stream; every later hook runs on the thread that picks that job back out of the buffer. Anything thread-affine — a thread-local, an open span you meant to close, a connection checked out of a pool — will not survive the crossing. Hang it on [`job.context`](#reading-the-job) instead, which travels with the job. (Polling workers, and streaming workers configured `buffer: false`, activate and execute on one thread; `job.buffered?` tells you which case you're in.)

### Reading the Job

The carrier is the same `Busybee::Job` your worker sees — everything in [Direct Job Access](workers.md#direct-job-access) applies: `key`, `type`, `variables`, `headers`, `retries`, `deadline`, the status predicates, and so on. Hooks get some additional context on top:

**Activation facts** — how the job got here:

| Reader | Value |
|--------|-------|
| `job.source` | `:poll` or `:stream` — which receive path delivered it |
| `job.buffered?` | whether it waited in a runner buffer |
| `job.worker_class` | the worker class handling it |
| `job.worker` | the worker *instance* (available once perform setup begins) |
| `job.worker_status` | a fresh [`Worker::Status`](#reading-workerstatus) snapshot of the worker processing it |

`job.worker_status` is how job hooks see worker-level gauges continuously — buffer depth, job counters — rather than only at the four worker-lifecycle moments.

**Outcome** — `job.status`, `job.result`, `job.error`, `job.error_message`, `job.error_code`, and the predicates (`ready?`, `complete?`, `failed?`, `error?`, `resolved?`).

**Timestamps** — each lifecycle moment, readable as UTC (default) or monotonic (`job.executed_at(:monotonic)`); `nil` until stamped:

| Timestamp | Stamped when |
|-----------|--------------|
| `activated_at` | the runner received the job |
| `execution_started_at` | the execution envelope opened |
| `perform_started_at` | `perform` began |
| `perform_finished_at` | `perform` returned or raised |
| `resolved_at` | the job resolved (complete / fail / BPMN error) |
| `executed_at` | the runner finished with the job |

**Durations** — computed from the monotonic stamps, in milliseconds, `nil` until both ends exist:

| Reader | Measures |
|--------|----------|
| `buffer_latency_ms` | activation → execution start (buffer/queue wait) |
| `setup_duration_ms` | execution start → perform start (validation, before-hooks) |
| `perform_duration_ms` | your `perform` method |
| `resolution_duration_ms` | execution start → resolved |
| `post_resolution_ms` | resolved → runner finished |
| `execution_duration_ms` | execution start → runner finished |
| `total_duration_ms` | activation → resolved |

**Cross-hook scratch** — `job.context` is a key/value bag for your hooks' own state, ideal for carrying something from a `before` to an `after`:

```ruby
config.before_perform { |job| job.context[:span] = Tracer.start_span(job.job_type) }
config.after_perform  { |job| job.context[:span].finish }
```

Primitive values you put in `job.context` also show up in `job.logging_context`; complex objects stay out of the logs.

## Worker Hooks

### The Four Moments

A worker process run has four observable moments, in order:

| Hook | Fires when |
|------|-----------|
| `on_worker_started` | the run began — the worker is about to start fetching jobs |
| `on_worker_stop_requested` | something asked the worker to stop (signal, health trigger, code); fires on the requesting thread |
| `on_worker_stopping` | the worker began its shutdown drain — intake is closed, in-flight work finishing |
| `on_worker_shutdown` | the run is over; the closing snapshot carries the final counters, `reason`, and `error` |

Each firing receives a **fresh, frozen `Busybee::Worker::Status`** snapshot. When several workers run in one process, each worker's runner fires its own hooks — filter on `worker_class:` or `job_type:` to scope.

```ruby
config.on_worker_started  { |worker| Monitoring.worker_up(worker) }
config.on_worker_shutdown { |worker| Monitoring.worker_down(worker) }
```

### Reading Worker::Status

| Group | Readers |
|-------|---------|
| Identity | `worker_class`, `job_type`, `worker_mode`, `worker_name` (the process-level identity from `Busybee.worker_name`) |
| Declared contract | `inputs`, `outputs`, `description` — the worker class's DSL declarations, for registering worker metadata in external systems |
| Counters | `total_job_count`, `failed_job_count`, `backpressure_count` |
| Buffer gauges | `current_buffer_size`, `peak_buffer_size` (`nil` on non-buffering workers) |
| Timing | `started_at`, `stop_requested_at`, `stopping_at`, `shutdown_at`, `uptime_s`, `stop_latency_ms`, `stop_duration_ms` |
| Outcome | `reason`, `error`, `error_class`, `error_message` |
| Projections | `context_tags`, `logging_context` |

A `nil` reader means "not known yet": `reason` and `error` are `nil` until the run ends, `stop_duration_ms` until the drain finishes, and so on. `uptime_s` is live — it reads the clock each call, so it keeps ticking even on a snapshot taken earlier.

### Stop Reasons

The closing snapshot answers *why* the worker stopped, as a machine-readable Symbol. This vocabulary is a contract you can filter and alert on:

| `reason` | Meaning |
|----------|---------|
| `:signal` | a graceful stop with no stated cause — the programmatic default |
| `:sigint` / `:sigterm` / `:sigquit` | the CLI received that signal |
| `:unhealthy` | the worker declared itself down — an error matched [`shutdown_on`](workers.md#shutdown-handling) |
| `:gateway_error` | an unrecovered gRPC failure — busybee couldn't reach the engine |
| `:gateway_closed` | the engine closed the job stream cleanly on its own |
| `:crash` | any other unhandled error ended the run |
| `:kill` | forced shutdown (`kill!`, or the CLI's second signal) |
| *anything else* | app-supplied — any Symbol your own code passes to `stop!(reason:)` |

Two prefix families make coarse filters easy: `reason: /\Asig/` matches every signal-driven stop, and `reason: /\Agateway/` matches both engine-driven endings.

**`reason` and `error` are independent axes.** The reason classifies the ending; the error, when present, is the exception involved. An `:unhealthy` stop carries the error that triggered it; a `:sigterm` stop usually carries none; and an app-supplied reason may carry either. Don't infer one from the other — read both.

```ruby
# Page only on stops that weren't asked for
config.on_worker_shutdown(reason: %i[unhealthy gateway_error crash]) do |worker|
  Alerting.page("worker down: #{worker.worker_name}", worker.logging_context)
end
```

## Call Hooks

The client's gRPC operations — fetching jobs, completing them, publishing messages, deploying processes — run through the call seam:

| Hook | Fires | Character |
|------|-------|-----------|
| `before_call` | once, before the operation starts | **Gating** — an error raised here aborts the operation |
| `around_call` | around **each network attempt** — a retried call fires it per attempt | Observing |
| `after_call` | exactly once, when the operation resolves (success or error) | Observing |

`around_call` wrapping attempts rather than the whole operation is the point: busybee performs its own retries (they're never delegated to the gRPC layer), so every attempt is individually visible, and `call.attempts` always tells the truth.

```ruby
# One metric per logical call, tagged with outcome
config.after_call { |call| StatsD.distribution("zeebe.call_ms", call.network_ms, tags: call.context_tags) }

# Spot retry storms
config.after_call(status: :succeeded) do |call|
  Rails.logger.warn("call succeeded after retry #{call.logging_context.to_json}") if call.attempts > 1
end
```

### Reading the Call

| Group | Readers |
|-------|---------|
| Identity | `rpc` (Symbol, see below), `request` (the protobuf request) |
| Outcome | `status` (`:pending` / `:succeeded` / `:errored`), `pending?`, `succeeded?`, `errored?`, `resolved?`, `grpc_status` (`:ok` on success, the gRPC status Symbol like `:resource_exhausted` on failure), `result`, `error`, `error_class`, `error_message`, `attempts` |
| Timing | `network_ms` (this attempt on the wire), `cumulative_network_ms` (all attempts), `backoff_ms` (gap between retries), `queue_ms` (construction → first attempt), `total_ms` (whole logical call), plus `created_at` / `resolved_at` / `network_started_at` / `network_finished_at` moments |
| Correlation | `job` — the job this call ran on behalf of, when there is one; `worker_status` — the worker it ran in |
| Projections | `context_tags`, `logging_context` |

The `rpc` values mirror the engine's gateway API:

| Category | `rpc` |
|----------|-------|
| Job fetching | `:activate_jobs`, `:stream_activated_jobs` |
| Job resolution | `:complete_job`, `:fail_job`, `:throw_error` |
| Job maintenance | `:update_job_retries`, `:update_job_timeout` |
| Messaging | `:publish_message`, `:broadcast_signal` |
| Process control | `:create_process_instance`, `:cancel_process_instance`, `:deploy_resource` |
| Variables & incidents | `:set_variables`, `:resolve_incident` |

Correlation is automatic: a call made during `perform` (including automatic completion/failure, and `job.complete!` from any thread) carries its `call.job`, and any call made inside a running worker carries `call.worker_status`. A fetch call that precedes any job carries only the worker. The call's own `context_tags`/`logging_context` fold in a curated slice of both identities, so tagging a metric with `call.context_tags` already says which worker and job type produced it.

### Fetching Is Observed at Dispatch

Job fetching is the one place where the seam currently sees less than the whole story, and it's worth knowing before you build a dashboard on it.

`:activate_jobs` and `:stream_activated_jobs` are server-streaming RPCs, and the call resolves when the stream **opens** — before a single job has arrived. The hooks all fire, and `before_call` can inspect or annotate the request as usual, but what `after_call` reports is the dispatch: a `network_ms` near zero, a live enumerator as `result`, and `:succeeded` even when the broker goes on to report a failure while jobs are being read.

The gap is in the telemetry, not in the behavior. A fetch failure still reaches your worker as a `Busybee::GRPC::Error` with `grpc_status` intact; backpressure is still backed off and retried; the ending still arrives at `on_worker_shutdown` as `:gateway_error`. What you can't do today is watch a fetch fail *through `after_call`* — so alert on worker shutdown reasons rather than on fetch-call outcomes. Per-attempt fetch telemetry lands with the async work in v0.5.

## When Hooks Raise

What happens when a hook itself raises an error depends on the hook's character:

| Hooks | An error raised in the hook… |
|-------|------------------------------|
| `before_perform`, `around_perform` | **propagates** — the job takes the same path as an error raised by `perform` itself (automatic failure, `shutdown_on` check) |
| `before_call` | **propagates** — the client call never happens; the caller sees the error |
| `after_perform`, `on_job_*`, `around_job_execution`, `on_worker_*`, `around_call`, `after_call` | is **logged and swallowed** — one misbehaving observer can't break job processing, other hooks, or shutdown |

Every swallowed error is logged with its class, message, and origin, so a broken hook is visible without being fatal.

The swallow covers `StandardError`, which is every error you would normally raise or rescue. It deliberately does not cover the rest of Ruby's exception hierarchy: a `NoMemoryError` or a `SystemStackError` from an observation hook propagates like any other, because a process in that condition should not have its symptoms suppressed by a metrics call.

Two deliberate exceptions to the swallowing:

- **`Busybee::Worker::Shutdown` always propagates**, from any hook — including the observing ones. Raising it is the supported way for a hook to declare the worker unhealthy.
- **Errors matching `shutdown_on` escalate to a graceful shutdown**, from any hook — a hook that detects a dead database connection gets the same treatment as a `perform` that does. The demo app uses exactly this to simulate rolling restarts from an `around_perform` hook.

  Escalation reads the *worker's* `shutdown_on` list plus the gem-wide [`Busybee.shutdown_on_errors`](configuration.md#shutdown_on_errors). Call hooks have no worker to read — a client call can be made from a web request or a background job, where "shut this worker down" means nothing — so only the gem-wide list escalates from `before_call`, `around_call`, and `after_call`. Put an error class in `Busybee.shutdown_on_errors` if you want it to escalate from anywhere.

## Hooks and Threads: Own What You Spawn

Hooks run synchronously on busybee's worker threads, so observability hooks often hand their real work — database writes, HTTP posts to a telemetry endpoint — to a background thread or executor. That's the right instinct, with one obligation attached: **any thread your hooks spawn needs an owner who shuts it down. Busybee cannot do it for you, and the failure mode of skipping it is severe.**

### The Failure Mode

Ruby's process exit runs in a fixed order: `at_exit` handlers first, then **all remaining threads are killed wherever they stand**, then finalizers run. A writer thread killed mid-write inside a native extension (a database driver, a compressor) can die while holding a native lock. The finalizer pass then tries to close that same resource, blocks on the orphaned lock, and the process hangs *after* its Ruby code has finished — forever.

The resulting zombie is nasty to operate against:

- The crash output (if any) has already printed, but the process never exits.
- `SIGTERM`/`SIGINT` do nothing — the VM is past the point of dispatching traps.
- Container restart policies never fire, because the process never dies; a liveness check that only asks "is the process up?" stays green.
- Meanwhile the worker fetches nothing, and its job types starve.

If you see a worker in that state — exit initiated, process alive, signals inert, and (if you attach a debugger) the main thread parked in a native mutex wait under the VM's cleanup/finalizer frames — suspect an unowned thread killed while holding a native lock.

### The Drain Pattern

Give every hook-spawned thread a drain path that runs *before* the thread-kill step. `at_exit` handlers run first, which makes them the natural home:

```ruby
# The executor your observation hooks post writes to
WRITER = Concurrent::SingleThreadExecutor.new(fallback_policy: :discard)

# Drain before Ruby starts killing threads
at_exit do
  WRITER.shutdown
  WRITER.wait_for_termination(10)
end
```

Pair it with a flush on `on_worker_shutdown` so the final observations of a stopping worker land deterministically, even though other workers in the process may still be running:

```ruby
config.on_worker_shutdown do |_worker|
  latch = Concurrent::CountDownLatch.new(1)
  WRITER.post { latch.count_down }
  latch.wait(5) # everything posted before this point has been written
end
```

For a complete worked example — snapshot-synchronously-then-post, out-of-order-safe writes, the `at_exit` drain, and the shutdown flush — see the demo app's [`Monitoring::Recorder`](../spec/demo/app/services/monitoring/recorder.rb).

## Observing Deferred Resolutions

`on_job_executed` marks the moment `perform` returned and the runner moved on. Usually the job has resolved by then — but if your worker resolves jobs *later* (calling `job.complete!` from another thread after `perform` returns), no job hook fires at that later moment.

The resolution is still observable: it's a gRPC call, and call hooks see every one of them. Job resolution calls carry their `call.job` even from another thread, so you can fold the outcome into your own records:

```ruby
RESOLUTION_OUTCOMES = { complete_job: "complete", fail_job: "failed", throw_error: "error" }.freeze

config.after_call(rpc: RESOLUTION_OUTCOMES.keys, status: :succeeded) do |call|
  next unless call.job # resolution calls made outside any job context

  Monitoring.job_resolved(call.job.key, RESOLUTION_OUTCOMES.fetch(call.rpc))
end
```

The demo app's recorder uses this exact fold to keep its per-job records accurate for asynchronously-resolved jobs. A first-class resolution hook is planned alongside broader async-worker support in a future version; until then, `after_call` on the three resolution RPCs is the reliable signal.

## Test Isolation

Hook registrations are global and survive across examples. If your test suite registers hooks (or boots an app that does), clear them where you need a clean slate:

```ruby
RSpec.configure do |config|
  config.before(:each, :clean_hooks) { Busybee::Hooks.reset! }
end
```

`Busybee::Hooks.reset!` empties every hook type's registry. Note that it removes *all* hooks — including any your application registered at boot — so re-register what the code under test depends on.
