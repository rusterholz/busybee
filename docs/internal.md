# Busybee Internals

This document describes the internal architecture of the busybee gem. It is for maintainers and contributors who need to understand how the pieces fit together.

**Note:** This document is not linked from the README. For development setup, running tests, and release procedures, see [docs/development.md](development.md).

## Architecture Overview

```
lib/busybee/
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
├── job.rb                   # Job wrapper for activated jobs
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
│   │   └── support.rb       # Private helper methods
│   └── matchers/            # RSpec custom matchers
│       ├── have_activated.rb
│       ├── have_available_jobs.rb
│       ├── have_received_headers.rb
│       └── have_received_variables.rb
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

All setters validate their inputs and raise `ArgumentError` with messages naming the config attribute and expected types. Validation patterns: duration (Integer, Duration, numeric String), boolean, string (String/Symbol), queue throttle (Numeric/boolean/numeric String), runner mode (valid Symbol/String), error class list (Array of Exception subclasses). Numeric-looking Strings from ENV/YAML are coerced; non-integer Numeric durations are coerced to Integer with a logged warning. `nil` always resets to default.

The Railtie passes Rails config values through these setters. It pre-coerces booleans with `!!` (standard Rails practice) but otherwise relies on the setters for validation.

## Logging Module

`Busybee::Logging` provides prefixed log output in text or JSON format. A mutex serializes the format + write path so concurrent threads (e.g., multiple Worker runners) cannot interleave within a single log line. The nil-logger guard runs outside the mutex to avoid unnecessary lock acquisition.

## Worker Module

`Busybee::Worker` is the base class for user-defined job workers. A Worker subclass declares its metadata via a class-level DSL and implements `perform` to handle jobs.

### Structure

```
Worker                      # Base class: perform_job lifecycle, Shutdown error, job delegation
├── Worker::DSL             # Class-level DSL methods (extended into Worker subclasses)
├── Worker::Configuration   # Stores all DSL-declared metadata per worker class
│   ├── Configuration::Input   # Struct for declared inputs
│   └── Configuration::Output  # Struct for declared outputs
└── Worker::Shutdown        # Error class signaling runner should shut down
```

**Configuration** is lazily instantiated per worker class (`@_configuration ||= Configuration.new(self)`). The DSL module's class methods (e.g., `job_type`, `input`, `streaming`) delegate to Configuration, which validates and stores the values. Configuration also resolves runtime options by merging DSL-level settings with gem-level defaults (e.g., `queue_throttle` falls back to `Busybee.default_queue_throttle`).

### perform_job Lifecycle

`Worker.perform_job(job)` is the entry point called by Runners. Its contract:

- **Returns normally:** job was handled (completed, failed, or BPMN-errored). Runner continues.
- **Raises `Worker::Shutdown`:** worker is unhealthy (matched `shutdown_on` exception). Runner should shut down.

Steps:
1. Instantiate worker with job
2. Validate required inputs (raises `MissingInput` listing all missing names)
3. Call `instance.perform`
4. **On success:** if `complete_job_on_success` and `job.ready?`, validate required outputs, call `job.complete!`. GRPC errors logged and swallowed.
5. **On error:** if `fail_job_on_error` and `job.ready?`, call `job.fail!`. Then check `shutdown_on` — if matched, wrap as `Shutdown` and re-raise.

The `job.ready?` guard on both auto-complete and auto-fail respects manual `complete!`/`fail!`/`throw_bpmn_error!` calls within `perform`.

## Runtime Configuration

`Busybee::RuntimeConfig` holds operator-specified overrides, typically from CLI flags or YAML config. It has a two-phase lifecycle:

1. **Constructed sparse** — only fields the operator explicitly set. Per-worker overrides keyed by class name. This is the YAML-shaped input.
2. **Resolved via `resolve_for(worker_class)`** — returns a new RuntimeConfig with all values populated through the precedence chain: per-worker RuntimeConfig → global RuntimeConfig → worker DSL → gem defaults.

Runners hold the resolved config at runtime. The resolved config is a flat RuntimeConfig (no per-worker nesting) with every field set.

### Precedence Chain

For any field (currently `runner_mode`; future: `backpressure_delay`, `shutdown_backoff`, etc.):

```
Per-worker RuntimeConfig override   (highest priority)
         ↓
Global RuntimeConfig value
         ↓
Worker DSL (worker_class.configuration)
         ↓
Gem default (Busybee.default_*)     (lowest priority)
```

### Integration Points

- **`Runner.for`** accepts `runtime_config:`, calls `resolve_for` to determine runner class.
- **`Runner::Multi`** calls `resolve_for` per worker class, so each child runner gets its own resolved config.
- **CLI** (Mission 14) will construct a RuntimeConfig from parsed flags and pass it to `Runner.for`.
- **YAML config** (Mission 15) will construct a RuntimeConfig from parsed YAML.

## Runner Module

Runners are long-lived processes that fetch jobs and dispatch them to Workers. All runner types inherit from `Busybee::Runner`, providing a uniform interface for the CLI.

### Class Hierarchy

```
Runner                    # Base class: run!, stop!, stopping?, running?, kill!, factory
├── Runner::Polling       # Loop using client.with_each_job
├── Runner::Streaming     # Loop using client.open_job_stream (dual-mode: inline or pump+queue)
│   └── Runner::Hybrid    # Subclass of Streaming, adds poll-drain phase before queue processing
└── Runner::Multi         # Thread pool managing multiple single-worker runners
```

**Key design decision:** `Hybrid < Streaming`, not `Hybrid < Runner`. Hybrid's unique contribution is the drain phase — all pump thread and queue machinery is inherited from Streaming.

### Threading Model

**Sequential processing guarantee:** In v0.3, all `perform_job` calls happen on the main thread. Worker authors do not need to think about concurrency.

- **Polling:** single-threaded. `with_each_job` yields jobs sequentially.
- **Streaming (inline mode, `queue: false`):** single-threaded. `stream.each` calls `perform_job` directly.
- **Streaming (queue mode, `queue: true`, default):** two threads. A **pump thread** reads from the gRPC stream into a `Queue`; the **main thread** pops and processes. The pump thread never calls `perform_job`.
- **Hybrid:** two threads (inherited from Streaming queue mode). Main thread first polls to drain the backlog (interleaving stream jobs between poll batches), then transitions to queue-only processing.

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

### Queue Throttle

When `queue_throttle` is configured on a worker, the pump thread sleeps between stream reads. This controls the trade-off between queue growth (affecting memory) and job latency:

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
