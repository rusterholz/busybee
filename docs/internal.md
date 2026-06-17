# Busybee Internals

This document describes the internal architecture of the busybee gem. It is for maintainers and contributors who need to understand how the pieces fit together.

**Note:** This document is not linked from the README. For development setup, running tests, and release procedures, see [docs/development.md](development.md).

## Architecture Overview

```
exe/
└── busybee                  # CLI executable (thin shim)
lib/busybee/
├── cli.rb                   # CLI entry point: arg parsing, env loading, signal handling, runner wiring
├── configure.rb             # Validated setters for gem-level config (included into Busybee singleton)
├── client.rb                # Client class - main user-facing API
├── client/                  # Client operation modules
│   ├── error_handling.rb    # Retry logic and error wrapping
│   ├── job_operations.rb    # complete_job, fail_job, with_each_job, etc.
│   ├── message_operations.rb # publish_message, broadcast_signal
│   ├── process_operations.rb # deploy_process, start_instance, cancel_instance
│   └── variable_operations.rb # set_variables, resolve_incident
├── credentials.rb           # Credentials base class and factory
├── credentials/             # Credential implementations
│   ├── camunda_cloud.rb     # Camunda Cloud OAuth (auto-configured)
│   ├── insecure.rb          # Local development (no TLS)
│   ├── oauth.rb             # Generic OAuth2 client credentials
│   └── tls.rb               # TLS with optional client cert
├── defaults.rb              # Default values (timeouts, retry delays, etc.)
├── error.rb                 # Base error class and subclasses
├── grpc.rb                  # GRPC module entry point
├── grpc/                    # Generated protocol buffer classes
│   ├── error.rb             # GRPC::Error wrapper
│   ├── gateway_pb.rb        # Message definitions (generated)
│   └── gateway_services_pb.rb # Service stubs (generated)
├── hooks.rb                 # Hooks module: registration, prefilter matching, invocation
├── hooks/                   # Hook system internals
│   └── chain.rb             # Builds the nested around-hook lambda chain (propagating + safe forms)
├── job.rb                   # Job: the authoritative lifecycle object (wraps the protobuf, owns the POROs below)
├── job/                     # Job's typed helper POROs
│   ├── activation.rb        # Receive-time facts: source, buffer_size, worker, worker_class
│   ├── context.rb           # Arbitrary cross-hook scratch + cardinality-aware projections
│   ├── error_formatting.rb  # Error message/code formatting (mixed into Job)
│   ├── payload.rb           # Wraps the GRPC ActivatedJob: key, type, variables, headers, retries, deadline
│   ├── resolution.rb        # Outcome: status, result, error trio; resolve_to / set_result / set_error
│   └── timestamps.rb        # Monotonic + UTC lifecycle stamps and duration projections
├── job_stream.rb            # JobStream for streaming job activation
├── logging.rb               # Logging module (text/JSON, thread-safe)
├── railtie.rb               # Rails integration
├── runtime_config.rb        # Operator-specified runtime overrides (CLI/YAML → resolved config)
├── runner.rb                # Runner base class, factory method, shared shutdown logic
├── runner/                  # Runner implementations
│   ├── hybrid.rb            # Hybrid runner (Streaming subclass, adds poll-drain phase)
│   ├── multi.rb             # Multi runner (thread pool managing multiple single-worker runners)
│   ├── polling.rb           # Polling runner (with_each_job loop)
│   └── streaming.rb         # Streaming runner (open_job_stream, pump thread + queue)
├── serialization.rb         # JSON serialization/deserialization
├── testing.rb               # Testing module entry point
├── testing/                 # RSpec integration
│   ├── activated_job.rb     # Fluent job wrapper for tests
│   ├── helpers.rb           # deploy_process, with_process_instance, etc.
│   ├── helpers/
│   │   ├── execution.rb     # build_test_job, execute_worker (unit testing workers)
│   │   └── support.rb       # Private helper methods
│   └── matchers/            # RSpec custom matchers
│       ├── complete_job.rb  # expect(Worker).to complete_job(job).with_vars(...)
│       ├── fail_job.rb      # expect(Worker).to fail_job(job).with_error(...)
│       ├── have_activated.rb
│       ├── have_available_jobs.rb
│       ├── have_received_headers.rb
│       ├── have_received_variables.rb
│       └── throw_bpmn_error_on.rb  # expect(Worker).to throw_bpmn_error_on(job).with_code(...)
├── version.rb               # Gem version
├── worker.rb                # Worker base class, perform_job lifecycle, Shutdown error
└── worker/                  # Worker support classes
    ├── configuration.rb     # Stores DSL-declared metadata per worker class
    └── dsl.rb               # Class-level DSL methods (job_type, input, output, etc.)
```

## Component Dependencies

```
                    ┌─────────────────┐
                    │  Busybee::GRPC  │  (generated, lowest level)
                    └────────┬────────┘
                             │
              ┌──────────────┼──────────────┐
              │              │              │
              ▼              │              │
    ┌─────────────┐          │              │
    │   Testing   │          │              │
    └─────────────┘          │              │
                             ▼              │
                    ┌─────────────┐         │
                    │   Client    │         │
                    └──────┬──────┘         │
                           │                │
                    ┌──────┴──────┐         │
                    │   Worker    │ ────────┘
                    │             │  (also uses GRPC for streaming)
                    └──────┬──────┘
                           │
                    ┌──────┴──────┐
                    │   Runner    │  (uses Client + Worker)
                    └──────┬──────┘
                           │
                    ┌──────┴──────┐
                    │     CLI     │  (uses Client + Runner + RuntimeConfig)
                    └─────────────┘

    ┌─────────────┐
    │   Railtie   │  (optional, configures Client/Worker/Runner from Rails)
    └─────────────┘
```

- **GRPC** is the foundation; all other components build on it
- **Testing** uses GRPC directly (doesn't need Client abstraction)
- **Client** wraps GRPC with Ruby-idiomatic interface
- **Worker** defines job handling logic; uses Client for job operations (complete, fail), plus GRPC directly for streaming
- **Runner** orchestrates Workers — uses Client to fetch/stream jobs, dispatches to Worker's `perform_job`
- **Railtie** is optional; it reads Rails config and sets up gem-level configuration for Client, Worker, and Runner defaults

## Gem-Level Configuration

Gem-level configuration (`Busybee.cluster_address`, `Busybee.default_message_ttl`, etc.) is split across two files:

- **`busybee.rb`** — Readers, defaults, constants, and `configure`. This is the public surface: reading the file shows what config exists and what the defaults are.
- **`configure.rb`** — `Busybee::Configure` module with validated setters and private validation helpers. Included into Busybee's singleton class (`class << self; include Configure`).

All setters validate their inputs and raise `ArgumentError` with messages naming the config attribute and expected types. Validation patterns: duration (Integer, Duration, numeric String), boolean, string (String/Symbol), buffer throttle (Numeric/boolean/numeric String), worker mode (valid Symbol/String), error class list (Array of Exception subclasses). Numeric-looking Strings from ENV/YAML are coerced; non-integer Numeric durations are coerced to Integer with a logged warning. `nil` always resets to default.

The Railtie passes Rails config values through these setters. It pre-coerces booleans with `!!` (standard Rails practice) but otherwise relies on the setters for validation.

## Logging Module

`Busybee::Logging` provides prefixed log output in text or JSON format. A mutex serializes the format + write path so concurrent threads (e.g., multiple Worker runners) cannot interleave within a single log line. The nil-logger guard runs outside the mutex to avoid unnecessary lock acquisition.

## Worker Module

`Busybee::Worker` is the base class for user-defined job workers. A Worker subclass declares its metadata via a class-level DSL and implements `perform` to handle jobs.

### Job and Client Access

Worker delegates `variables`, `headers`, `client`, `fail!`, `throw_bpmn_error!`, `update_retries`, and `update_timeout` to `job`. The `job` reader is also public. `complete!` is defined on Worker (not delegated) — it validates required and undeclared outputs before delegating to `job.complete!`.

`Job#client` exposes the `Busybee::Client` instance that fetched the job. Workers can use `client` inside `perform` for direct API access — e.g., `client.publish_message(...)` for message correlation. The client reuses the existing gRPC connection, so there's no additional connection overhead.

### Structure

```
Worker                      # Base class: perform_job lifecycle, Shutdown error, job delegation
├── Worker::DSL             # Class-level DSL methods (extended into Worker subclasses)
├── Worker::Configuration   # Stores all DSL-declared metadata per worker class
│   ├── Configuration::Input   # Struct for declared inputs
│   └── Configuration::Output  # Struct for declared outputs
└── Worker::Shutdown        # Error class signaling runner should shut down
```

**Configuration** is lazily instantiated per worker class (`@_configuration ||= Configuration.new(self)`). The DSL module's class methods (e.g., `job_type`, `input`, `streaming`) delegate to Configuration, which validates and stores the values. Configuration also resolves runtime options by merging DSL-level settings with gem-level defaults (e.g., `buffer_throttle` falls back to `Busybee.default_buffer_throttle`).

**Strict outputs** (`strict_outputs` DSL, `Busybee.default_strict_outputs` gem-level) rejects undeclared output keys on completion. Default: `true`. Per-worker `strict_outputs false` disables the check for that worker. `Busybee.default_strict_outputs = false` disables gem-wide. The resolved value uses a three-state pattern: `nil` (DSL default) falls back to the gem-level setting via `Configuration#strict_outputs?`. Validation runs on both auto-complete and manual `complete!` calls (see below).

### perform_job Lifecycle

`Worker.perform_job(job)` is the entry point called by Runners. Its contract:

- **Returns normally:** job was handled (completed, failed, or BPMN-errored). Runner continues.
- **Raises `Worker::Shutdown`:** worker is unhealthy (matched `shutdown_on` exception). Runner should shut down.

Steps:
1. Instantiate worker with job
2. Validate required inputs (raises `MissingInput` listing all missing names)
3. Call `instance.perform`
4. **On success:** if `complete_job_on_success` and `job.ready?`, validate required outputs (`MissingOutput`), validate no undeclared outputs when `strict_outputs` is enabled (`UndeclaredOutput`), then call `job.complete!`. GRPC errors logged and swallowed.
5. **On error:** if `fail_job_on_error` and `job.ready?`, call `job.fail!`. Then check `shutdown_on` — if matched, wrap as `Shutdown` and re-raise.

The `job.ready?` guard on both auto-complete and auto-fail respects manual `complete!`/`fail!`/`throw_bpmn_error!` calls within `perform`.

**Output validation on manual `complete!`:** Worker defines its own `complete!(vars = {})` (not delegated to Job) that runs `validate_required_outputs!` and `validate_undeclared_outputs!` before delegating to `job.complete!`. Validation errors raised inside `perform` flow through `perform_job`'s normal rescue path — auto-fail when `fail_job_on_error` is true, logged when false. Code that calls `job.complete!` directly bypasses output validation (this is intentional for edge cases but not the recommended pattern).

### Job Execution Flows

Job execution flows — receive-to-runner-return walkthroughs for typical and edge-case lifecycle paths — are documented in [`internal/job_execution_flows.md`](internal/job_execution_flows.md).

## Runtime Configuration

`Busybee::RuntimeConfig` holds operator-specified overrides, typically from CLI flags or YAML config. It has a two-phase lifecycle:

1. **Constructed sparse** — only fields the operator explicitly set. Per-worker overrides keyed by class name.
2. **Resolved via `resolve_for(worker_class)`** — returns a new RuntimeConfig with all values populated through the precedence chain: per-worker RuntimeConfig → global RuntimeConfig → worker DSL → gem defaults.

Runners hold the resolved config at runtime. The resolved config is a flat RuntimeConfig (no per-worker nesting) with every field set.

### Fields

RuntimeConfig fields are divided into two categories:

**Worker-scoped** — participate in the full 4-level precedence chain (per-worker RC → global RC → worker DSL → gem default). Only `worker_mode` has a CLI flag (`-m`); the rest are YAML-only:
- `worker_mode` — `:polling`, `:streaming`, or `:hybrid`
- `backpressure_delay` — ms to sleep on `GRPC::ResourceExhausted`
- `max_jobs` — max jobs per poll request
- `request_timeout` — long-poll timeout in ms
- `buffer` — whether the streaming pump+buffer is used (`true` by default)
- `buffer_throttle` — pump thread delay in ms (`false` = no throttle)
- `job_timeout` — job lock timeout in ms
- `backoff` — fail-job backoff in ms

**Process-wide** — apply globally, no per-worker overrides (global RC → gem default):
- `log_format` — `:text` or `:json`
- `worker_name` — identifier for this worker process
- `cluster_address` — Zeebe gateway address

### Precedence Chains

All worker-scoped fields use the same 4-level chain:

```
Per-worker RuntimeConfig override   (highest priority)
         ↓
Global RuntimeConfig value
         ↓
Worker DSL (worker_class.configuration)
         ↓
Gem default (Busybee.default_*)     (lowest priority)
```

All process-wide fields use the same 2-level chain:

```
Global RuntimeConfig value          (highest priority)
         ↓
Gem default (Busybee.*)             (lowest priority)
```

Resolution uses `first_non_nil` semantics: `0` and `false` are valid explicit values (important for `buffer_throttle: false` meaning "no throttle" and `backpressure_delay: 0` for testing).

### YAML Parsing

`RuntimeConfig.parse_yaml(path)` reads a YAML config file and returns a kwargs hash suitable for `RuntimeConfig.new(**result)`. Raw YAML types flow through — the constructor handles coercion (e.g., string `"polling"` → symbol `:polling` for `worker_mode`).

**Valid YAML keys:** All worker-scoped fields (`worker_mode`, `backpressure_delay`, `max_jobs`, `request_timeout`, `buffer`, `buffer_throttle`, `job_timeout`, `backoff`) plus `workers`. Process-wide fields (`log_format`, `worker_name`, `cluster_address`) are CLI-only and rejected in YAML.

**Workers format:** The `workers` key is a YAML list. Each entry is either a bare string (worker class name, no overrides) or a mapping with the worker name as key and overrides nested beneath it:

```yaml
workers:
  - SimpleWorker
  - TunedWorker:
      max_jobs: 32
      worker_mode: polling
```

`parse_workers` normalizes both forms into a hash keyed by worker name: `{ "SimpleWorker" => {}, "TunedWorker" => { max_jobs: 32, worker_mode: :polling } }`.

**Validation:** `parse_yaml` validates top-level keys (rejects unrecognized keys and process-wide fields) and per-worker override keys (rejects anything not in the worker-scoped set). Errors include the invalid key name and list valid options.

**String-to-symbol coercion:** The constructor accepts strings for `worker_mode` and `log_format` (necessary since `YAML.safe_load` produces strings). Values are validated against the string allowlist before coercion to prevent symbol injection. Both strings and symbols are accepted (backwards-compatible).

### Integration Points

- **`Runner.for`** accepts `runtime_config:`, calls `resolve_for` to determine runner class and build the resolved config passed to the runner.
- **`Runner::Multi`** calls `resolve_for` per worker class, so each child runner gets its own resolved config.
- **CLI** constructs a RuntimeConfig from parsed flags (or YAML config) and passes it to `Runner.for`. Process-wide fields (`log_format`, `worker_name`, `cluster_address`) are applied to gem config during initialization.
- **YAML config** (`--config` / `-c`) — `RuntimeConfig.parse_yaml(path)` reads a YAML file and returns a kwargs hash. The CLI merges process-wide CLI flags into the YAML-sourced kwargs and constructs RuntimeConfig from the result.

## Runner Module

Runners are long-lived processes that fetch jobs and dispatch them to Workers. All runner types inherit from `Busybee::Runner`, providing a uniform interface for the CLI.

### Class Hierarchy

```
Runner                    # Base class: run!, stop!, stopping?, running?, kill!, factory
├── Runner::Polling       # Loop using client.with_each_job
├── Runner::Streaming     # Loop using client.open_job_stream (dual-mode: inline or pump+queue)
│   └── Runner::Hybrid    # Subclass of Streaming, adds poll-drain phase before buffer processing
└── Runner::Multi         # Thread pool managing multiple single-worker runners
```

**Key design decision:** `Hybrid < Streaming`, not `Hybrid < Runner`. Hybrid's unique contribution is the drain phase — all pump thread and queue machinery is inherited from Streaming.

### Threading Model

**Sequential processing guarantee:** In v0.3, all `perform_job` calls happen on the main thread. Worker authors do not need to think about concurrency.

- **Polling:** single-threaded. `with_each_job` yields jobs sequentially.
- **Streaming (inline mode, `buffer: false`):** single-threaded. `stream.each` calls `perform_job` directly.
- **Streaming (buffered mode, `buffer: true`, default):** two threads. A **pump thread** reads from the gRPC stream into a `Queue`; the **main thread** pops and processes. The pump thread never calls `perform_job`.
- **Hybrid:** two threads (inherited from Streaming buffered mode). Main thread first polls to drain the backlog (interleaving stream jobs between poll batches), then transitions to buffer-only processing.

### concurrent-ruby Primitives

| Primitive | Used For |
|-----------|----------|
| `Concurrent::AtomicBoolean` | `@stop_requested`, `@running` — thread-safe state flags |
| `Concurrent::AtomicReference` | `@shutdown_error` (Streaming/Hybrid), `@thread_error` (Multi) — first-error-wins |
| Ruby `Queue` | Job queue between pump thread and main thread (thread-safe) |
| `Concurrent::FixedThreadPool` | Multi runner — one thread per child runner |

### Error Handling

From the Runner's perspective, `perform_job` has a simple two-outcome contract (returns or raises `Shutdown`). All other exceptions are handled inside `perform_job`.

At the runner level:
- `GRPC::ResourceExhausted` → backpressure: sleep and retry
- `Worker::Shutdown` → store error, `stop!`, re-raise after clean exit
- Other errors → propagate up (to Multi/CLI). Likely fatal (auth, config).

### Shutdown Sequence

**Graceful (`stop!`):** Sets `@stop_requested` AtomicBoolean. For streaming/hybrid, also closes the stream (unblocks `stream.each`) and pushes a `:stop` sentinel to the queue (unblocks `queue.pop`). In-progress `perform_job` completes. Remaining queued/yielded jobs are failed via `handle_shutdown_job` (preserves retry count).

**Forced (`kill!`):** Base calls `stop!`. Streaming also kills the pump thread and flushes the queue. Multi kills all child runners and the thread pool.

### Buffer Throttle

When `buffer_throttle` is configured on a worker, the pump thread sleeps between stream reads. This controls the trade-off between buffer growth (affecting memory) and job latency:

- `false` (default) — no sleep, pump reads as fast as possible
- `0` — `sleep(0)`, minimal throttle (yields thread via nanosleep, ~1-5µs)
- Positive Numeric — explicit delay in milliseconds (e.g., `0.5` = 500µs)

Point of use: `sleep(delay.to_f / 1000) if delay` — works because `false` is falsey, `0` is truthy in Ruby.

### Multi Runner

`Runner::Multi` manages multiple worker types in a single process. Each worker class gets its own child runner (Polling, Streaming, or Hybrid, resolved via `Runner.for`) running in a dedicated thread.

**Threading model:** A `Concurrent::FixedThreadPool` sized to the number of worker classes. Each thread calls `runner.run!` on its child runner. The main thread calls `thread_pool.wait_for_termination` and blocks until all child threads exit.

**Error handling:** A `Concurrent::AtomicReference` captures the first error from any child thread (first-error-wins via `update { |prev| prev || e }`). When a child thread raises, Multi logs the error, calls `stop!` to cascade shutdown to all siblings, and after the pool terminates, re-raises the captured error.

**Shutdown sequence:**
- `stop!` — stops all child runners, then `thread_pool.shutdown` (waits for in-progress jobs to finish)
- `stopping?` — true only when *all* child runners are stopping
- `kill!` — kills all child runners, then `thread_pool.kill` (immediate termination)

**ActiveRecord connection pool check:** On initialization, if `ActiveRecord` is defined, Multi compares `connection_pool.size` against the number of worker classes. Logs an error if the pool is undersized (common misconfiguration), or an info message confirming adequate pool size.

**Shared client:** All child runners share the same `Busybee::Client` instance, passed through `Runner.for`. HTTP/2 multiplexing allows a single gRPC connection to serve all runners.

## CLI Module

`Busybee::CLI` is the entry point for the `busybee` executable. It parses arguments, loads the environment, resolves worker classes, and runs the appropriate runner.

### Structure

```
exe/busybee          # Thin shim: require "busybee" + CLI.main(ARGV)
lib/busybee/cli.rb   # CLI class: initialize (setup) + run (execution)
```

### Lifecycle

1. **`CLI.main(args)`** — class method entry point; instantiates and calls `run`.
2. **`initialize(args)`** — all setup: parse options (`OptionParser`), load Rails environment, extract workers from YAML if `--config`, load worker classes, build `RuntimeConfig`, apply process-wide config.
3. **`run`** — creates `Client`, calls `Runner.for` to get the appropriate runner, installs signal handlers, calls `runner.run!` (blocks).

### CLI Flags

The CLI exposes 5 flags. Worker-scoped tuning knobs (backpressure_delay, max_jobs, request_timeout, buffer, buffer_throttle, job_timeout, backoff) are YAML-only — they're per-worker concerns that don't belong on a command line.

- `--config` / `-c` — YAML configuration file path
- `--worker-mode` / `-m` — `:polling`, `:streaming`, or `:hybrid`
- `--log-format` / `-l` — `:text` or `:json`
- `--worker-name` / `-n` — worker process identifier
- `--cluster-address` / `-a` — Zeebe gateway address

**Mutual exclusions:** `--config` is mutually exclusive with `--worker-mode` (set worker_mode in YAML instead) and with positional worker args (list workers in YAML instead). Process-wide flags (`-l`, `-n`, `-a`) are allowed alongside `--config`.

**YAML config flow:** When `--config` is provided, the CLI calls `RuntimeConfig.parse_yaml` to get YAML-sourced kwargs, extracts worker class names from the `workers:` keys, merges CLI process-wide flags into the kwargs, and constructs RuntimeConfig from the result.

**Process-wide application:** `apply_global_config!` applies process-wide flags to gem config (e.g., `Busybee.log_format = :json`). Detects and logs when overriding values already set by the Railtie.

### Signal Handling

Traps `INT`, `QUIT`, `TERM` — all mapped to the same handler. The trap block spawns a thread and joins it (`Thread.new { handle_signal(signal) }.join`) to work around Ruby's signal trap restrictions (no mutex/thread pool operations in trap context).

**Two-signal pattern:**
- First signal → `runner.stop!` (graceful shutdown)
- Second signal (while `stopping?`) → `runner.kill!` + `exit!(1)` (forced shutdown, non-zero exit code, skips at_exit handlers)

### Rails Environment Loading

Attempts `require "rails"` — if `LoadError`, Rails is not available and loading is skipped silently. If Rails is present, loads `./config/environment` to boot the app (which triggers the Railtie). If environment loading fails, logs an error with the exception class and message, and suggests `BUSYBEE_SKIP_RAILS=1` as an escape hatch. The env var check happens before any `require` calls (chicken-and-egg: gem config isn't available yet since it's set by the Railtie).

### Error Classes

- **`Busybee::NoWorkersSpecified`** — no positional arguments given
- **`Busybee::WorkerNotFound`** — `Kernel.const_get` fails for a worker class name

## Serialization Module

`Busybee::Serialization` centralizes JSON handling for GRPC communication. This is **internal API** and may change without notice.

### Purpose

All Client methods and the Job class route JSON through this module to ensure:

1. **Consistent `as_json` behavior** — Serialization calls `as_json` before `JSON.generate`, so ActiveRecord models, Time objects, and custom classes serialize their JSON-friendly representation
2. **Consistent deserialization** — Parsing returns `HashWithIndifferentAccess` with the `HashAccess` module mixed in for method-style access
3. **Immutability** — Deserialized hashes are deeply frozen to prevent accidental mutation

### API

```ruby
# Serialization: Ruby → JSON string
Busybee::Serialization.to_json({ orderId: 123, user: User.find(1) })
# => '{"orderId":123,"user":{"id":1,"name":"Alice",...}}'

# Deserialization: JSON string → frozen hash with method access
hash = Busybee::Serialization.from_json('{"orderId":123}')
hash[:orderId]     # => 123
hash["orderId"]    # => 123
hash.orderId       # => 123
hash.order_id      # => 123 (snake_case → camelCase lookup)
hash.frozen?       # => true
```

### HashAccess Module

The `Busybee::Serialization::HashAccess` module provides method-style access with automatic snake_case to camelCase conversion:

- `hash.order_id` looks for `"order_id"` first, then `"orderId"`
- Nested hashes also get this behavior
- Only responds to methods that correspond to existing keys (no silent `nil` returns)

All Client operation modules, Job, and Testing helpers route through this module. Grep for `Serialization.to_json` and `Serialization.from_json` to find call sites.

## Hooks Module

`Busybee::Hooks` is the instrumentation system. It provides lifecycle hooks for jobs — enabling middleware (transactions, retry logic) and observation (metrics, tracing, error reporting). Worker- and call-level hook types are declared but not yet wired (see "Not yet wired" below).

### Job as the hook target

Job hooks receive the `Busybee::Job` itself:

```ruby
Busybee.configure do |c|
  c.before_job { |job| job.context[:span] = tracer.start_span(job.type) }
  c.after_job(status: :failed) { |job| Sentry.capture_exception(job.error) }
end
```

Job is the authoritative lifecycle object — there is no separate "event" mirror. The concerns a hook reads or annotates live on the Job through typed helper POROs, with readers delegated onto Job and writers kept internal to the POROs:

- **`Job::Payload`** — immutable facts from the activation protobuf: `key`, `type`, `variables`, `headers`, `retries`, `deadline`.
- **`Job::Activation`** — receive-time context: `source`, `buffer_size`, `worker`, `worker_class`. Populated by the Runner and Worker as the job is dispatched.
- **`Job::Resolution`** — the outcome: `status` (starts `:ready`), `result`, and the error trio (`error`, `error_message`, `error_code`), plus predicates (`ready?`, `completed?`, `failed?`, `errored?`, `resolved?`). Advanced exactly once, by the Job lifecycle methods (`complete!` / `fail!` / `throw_bpmn_error!`).
- **`Job::Timestamps`** — monotonic + UTC stamp pairs and the duration projections derived from them (see below).
- **`Job::Context`** — an opaque key/value bag for cross-hook scratch (the tracing-span use case above).

Hooks cannot mutate framework state through the Job: there are no public writers for status/result, and status changes are gated during hook execution — a `complete!`/`fail!` issued from inside a hook raises `Busybee::StatusChangeOutsidePerform`.

Two cardinality-aware projections aggregate state across the POROs for instrumentation:

- `job.context_tags` — low-cardinality, safe for metric labels
- `job.logging_context` — high-cardinality superset, for structured log fields

### Job Lifecycle Timestamps

`Job::Timestamps` captures six monotonic + UTC timestamp pairs, written via `job.timestamps.stamp!(name)`:

| Name | Stamped |
|------|---------|
| `activated_at` | Runner receives the job |
| `execution_started_at` | `perform_job` begins |
| `perform_started_at` | right before `instance.perform` |
| `perform_finished_at` | right after `instance.perform` returns or raises (stamped in an `ensure`) |
| `resolved_at` | top of `resolve!` (complete / fail / throw) |
| `executed_at` | Runner finishes the job (`execute_job`) |

Per-moment readers are forwarded on Job (`job.activated_at`, `job.executed_at`, …) — default `:utc`, pass `:monotonic` for the raw clock. Monotonic values back the seven duration projections (`perform_duration_ms`, `execution_duration_ms`, `total_duration_ms`, etc.); UTC values appear in structured log output. Accessors return `nil` before stamping.

### Hook Registration

Hooks are registered via `Busybee.configure`, which delegates to `Busybee::Hooks` (one registration method per `HOOK_TYPES` entry):

```ruby
Busybee.configure do |c|
  c.before_job { |job| ... }
  c.after_job(status: :failed) { |job| Sentry.capture_exception(job.error) }
  c.around_job { |job, perform| Datadog::Tracing.trace(job.type) { perform.call } }
end
```

Storage is plain arrays (one per hook type). Each entry is `{ callback:, filters: }`. FIFO ordering. No locking or concurrent data structures — hooks are registered at configure time and never modified after workers start. There is no supported use case for mutating hooks at runtime.

`Busybee::Hooks.reset!` clears all arrays (for test isolation).

### Prefiltering

Filter kwargs are validated per-noun at registration time (`FILTER_KEYS`):
- **Job hooks:** `job_type:`, `worker_class:`, `status:`, `bpmn_process_id:`, `source:`, `error:`
- **Worker hooks:** `worker_class:`, `job_type:`, `worker_mode:`, `error:`
- **Call hooks:** `method:`, `result:`, `error:`

At fire time, `Busybee::Hooks.matches?(hook, target)` reads each filter key off the target (`target.public_send(key)`, nil-safe) and applies `match?` — case equality (`===`) supporting Symbol/String (exact), Regexp (pattern), Class (`is_a?`), Proc (custom). Class values additionally match against their `.name` string, so `worker_class: "OrderWorker"` or `worker_class: /Order/` work regardless of load order. Empty filters match everything (vacuous truth). A filter value may also be an **array**, which matches if any element matches — `job_type: %w[create_shipment assign_driver]` fires for either, and the elements may mix matcher types.

Because filters resolve by sending the key name to the target, every filter key must name a real accessor on `Job`. Most line up directly; the exception is `job_type`, whose underlying protobuf field is `type` — `Job::Payload` aliases `job_type` to `type` (and `Job` delegates it) so `job_type:` filters resolve. A filter key that the target does not respond to reads as `nil` and silently never matches.

### Hook Invocation

- **`Busybee::Hooks.run(type, target, safe: false)`** — runs all matching hooks for a type. `safe: false` (default) lets errors propagate (wrapping hooks like `before_job`); `safe: true` logs and continues to the next hook (observing hooks like `after_job` and the `on_*` family). `Busybee::Worker::Shutdown` always propagates regardless, and errors matching the target's `shutdown_on` classes (worker config + gem-level) are wrapped in `Shutdown` and propagated.
- **`Busybee::Hooks.run_chain(type, target, safe:, &core)`** — builds a nested lambda chain from matching around hooks (via `Busybee::Hooks::Chain`) and wraps the core block. First-registered hook is outermost. The core's return value is harvested into the Job's `Resolution`, so middleware can't "forget" the result — it's always read back from the Job, never from the chain's return value. Zero matching hooks calls the core directly.

Worker and Runner call these directly at each job lifecycle moment (e.g. `Hooks.run(:after_job, job, safe: true)`); see the flows doc below for which hook fires where.

### Job execution flows

For receive-to-runner-return walkthroughs of the typical and edge-case lifecycle paths — including where each hook fires — see [`internal/job_execution_flows.md`](internal/job_execution_flows.md).

### Not yet wired

Worker-level (`on_worker_started`, `on_worker_stopping`, `on_worker_shutdown`) and call-level (`before_call`, `around_call`, `after_call`) hook types are declared in `HOOK_TYPES` and accept registration and filter validation, but do not fire yet. They're reserved for a future iteration that may give Workers and Calls their own lifecycle-object analogs to what Job does for jobs.

## Testing Module

`Busybee::Testing` provides RSpec integration for both BPMN integration tests (against a real Zeebe cluster) and unit tests (no Zeebe required).

### Architecture

- `testing.rb` — Entry point. Auto-loads helpers and matchers when RSpec is defined, includes `Helpers` into all examples.
- `testing/helpers.rb` — Integration test helpers (`deploy_process`, `with_process_instance`, `activate_job`, etc.) that talk to Zeebe via gRPC.
- `testing/helpers/execution.rb` — Unit test helpers (`build_test_job`, `execute_worker`) that run the full `Worker.perform_job` lifecycle against stub doubles. Uses `instance_double(Busybee::Client)` for the stub client (verifiable) and plain `double` for the protobuf raw job (dynamic accessors prevent verification).
- `testing/helpers/support.rb` — Private module-level helpers shared by integration test methods.
- `testing/matchers/` — Custom RSpec matchers for both integration and unit testing.

### Worker Unit Testing

`execute_worker` wraps `handle_failure` via `and_wrap_original` to re-raise errors after production failure logic runs. This lets tests assert both error type and job status. The three worker matchers (`fail_job`, `complete_job`, `throw_bpmn_error_on`) are built on top of `execute_worker` — they call it internally, then inspect the job and/or rescue the re-raised error.

### When to Use Matchers vs. execute_worker Directly

The matchers (`fail_job`, `complete_job`, `throw_bpmn_error_on`) cover the common case: assert job status and optionally verify error/vars/code. Use them when that's all you need.

Use `build_test_job` + `execute_worker` directly when you need to:
- Stub additional client methods (e.g., `publish_message`) via `job.client` and verify them with `have_received`
- Inspect side effects between execution and assertion
- Test retry/idempotency scenarios that call `perform_job` directly

See `spec/demo/spec/workers/delivery/complete_driver_delivery_worker_spec.rb` for an example of the "long" form with client interaction testing (stubbing `job.client` for `publish_message` verification).

### Matchers

| Matcher | Subject | Chains | Purpose |
|---------|---------|--------|---------|
| `fail_job(job)` | Worker class | `.with_error(class, msg)` | Asserts job failed with optional error match |
| `complete_job(job)` | Worker class | `.with_vars(hash)`, `.with_no_vars` | Asserts job completed with optional return value match |
| `throw_bpmn_error_on(job)` | Worker class | `.with_code(code, message: msg)` | Asserts BPMN error thrown with optional code/message match |
| `have_activated(type)` | Helper instance | `.with_variables(hash)`, `.with_headers(hash)` | Integration: asserts job activation |
| `have_available_jobs` | Block | — | Integration: asserts jobs exist |
| `have_received_variables(hash)` | ActivatedJob | — | Integration: asserts job variables |
| `have_received_headers(hash)` | ActivatedJob | — | Integration: asserts job headers |
