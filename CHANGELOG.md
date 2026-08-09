# Changelog

## Unreleased

### New Features:

- **Lifecycle Hooks** – Register callbacks to run at various lifecycle moments for middleware (transactions, retries) and observation (metrics, tracing, error reporting):
  - Worker lifecycle hooks: on process start, stop requested, stopping, and shutdown
  - Job lifecycle hooks: both logical, systemic lifecycle (on activated, on executed, around execution) and local, usercode lifecycle (before, after, and around the `perform` method)
  - Call lifecycle hooks: before, after, and around every GRPC call
  - Each callback receives a lifecycle object which exposes the appropriate information (status, gauges, counters, timestamps, durations, configuration) for that lifecycle
  - Callbacks may be prefiltered by attributes of the lifecycle object (e.g. register an after_perform callback only for failed jobs)
  - Lifecycle objects expose separate low-cardinality (for metric labels/tags) and high-cardinality (for logging) state projections
  - Support points for integrating with any APM / observability or error reporting platform: Datadog, NewRelic, Dynatrace, Airbrake, Sentry, etc.

- **Configurable Backpressure Statuses** – `Busybee.backpressure_statuses` (default `[:resource_exhausted]`) names the gRPC status codes that mean the gateway is applying backpressure. Polling and hybrid workers back off (sleeping `backpressure_delay`) and retry the fetch when a job-activation call resolves to one of these — matched by status code, independent of which gRPC exception class the gateway raised

- **gRPC Channel Keepalive** – HTTP/2 keepalive pings now guard the streaming worker's deadline-less job-activation stream, so a silently-dropped transport (a suspended host, a connection a proxy reset) surfaces as a recoverable gateway error instead of leaving the worker blocked forever. Tunable via `Busybee.grpc_keepalive_interval` (default 45s) and `Busybee.grpc_keepalive_timeout` (default 20s); set both to `false` to disable. Enabled by default

- **Timestamped JSON Logs** – every JSON-format log line now carries a `time` field (ISO8601 UTC, millisecond precision), so structured logs stay self-ordering even where the host logger's formatter — which normally supplies the timestamp — is bypassed or absent

- **Uniform Duration Inputs** – anywhere Busybee takes a length of time — client call arguments, gem-level configuration, the worker DSL, YAML, keepalive — you can write it the same way: a bare number for milliseconds, an `ActiveSupport::Duration` in whatever unit reads best, or a numeric String (handy for `ENV`-sourced config). Write `30.seconds` and stop counting zeroes
  - Fractions are kept as written and rounded only where a value reaches the wire, so `buffer_throttle: 0.1` means what it says
  - Every knob that takes a duration accepts every one of these shapes. The worker DSL, previously stricter than the configuration surface it mirrors, and `buffer_throttle` and `polling request_timeout:`, which each read their values a little differently, all now agree
  - Values arriving as a `Duration` reach the wire and the worker's own backoff correctly, not a thousand times too fast

- **A Warning When a Duration Looks Like a Units Slip** – a bare number means *milliseconds*, which makes `default_message_ttl = 30` a message that expires in thirty thousandths of a second. Busybee now notices and tells you exactly what to write instead:

  ```
  [busybee] default_message_ttl: 30ms seems unusually small for this setting. Durations here are
  milliseconds — if you meant 30 seconds, use 30000 or 30.seconds
  ```

  Your value is still applied — this advises rather than overrules. Deliberately tiny settings stay quiet: `0` means "no delay", `-1` is Zeebe's "answer immediately" for `request_timeout`, and `buffer_throttle` never warns, since sub-millisecond values are the point of it. Per-call arguments never warn either — a one-off `ttl:` is a decision, not a misconfiguration

- **Exposed Client on Job and Worker Delegation** – Easier access for other GRPC calls within your worker's `perform` method (like updating retries or publishing BPMN messages)
  - `client` in workers delegates to `job.client`, which returns the `Busybee::Client` instance that yielded the job

- **Strict Output Validation** – Stronger guards against data leakage into the workflow engine
  - Workers now validate that all output keys match declared `output` definitions; undeclared keys raise `Busybee::UndeclaredOutput`
  - Opt out per-worker with `strict_outputs false` or gem-wide via `Busybee.default_strict_outputs = false`
  - Manual `complete!` calls also validate outputs
  - Note: this feature is **on by default,** which is a breaking behavior change; see below

- **Improved Test Job Helper** – `Busybee::Testing::Helpers#build_test_job` now accepts an optional `key:` keyword argument for tests that need a stable, known job key (e.g., correlating the same job across multiple assertions). Defaults to a random integer when omitted

### Bug Fixes:

- **Workers Survive Gateway Backpressure** – a gateway reporting `RESOURCE_EXHAUSTED` to a polling or hybrid worker used to crash it, and in a multi-worker process took every sibling worker down with it — so a fleet-wide broker slowdown became a fleet-wide outage. Job activation is a server-streaming call whose status arrives while responses are being read, and that error was escaping untranslated past the very rescue meant to catch it. It now reaches the worker as a `Busybee::GRPC::Error` with `grpc_status` intact, so the documented backoff-and-retry runs and the process stays up
  - `Client#with_each_job` now keeps the `Busybee::GRPC::Error` contract its documentation promises, whatever status the gateway returns

- **Backoff and Retry Delays Wait the Length You Configured** – three settings were measured in milliseconds on the way in and then slept as though they were something else, so none of them waited what you asked for:
  - `backpressure_delay` parked a worker for its value in **seconds**: the default of `2_000` meant a worker vanished for over half an hour on a single backpressure event, and the documented `10_000` example for nearly three hours. It now waits two seconds
  - `grpc_retry_delay` and `buffer_throttle` had the opposite fault, and only when set with an `ActiveSupport::Duration`: `grpc_retry_delay = 0.5.seconds` retried after half a *millisecond*. Both now honour a `Duration` exactly as they honour a number
  - A sub-second `Duration` no longer rounds to zero on its way to a wait, so `0.25.seconds` means a quarter second rather than no pause at all

### Breaking Changes:

- **Testing helper `publish_message` parameters renamed** – `variables:` is now `vars:` and `ttl_ms:` is now `ttl:` to match `Client#publish_message` naming. `ttl:` now accepts both Integer (milliseconds) and `ActiveSupport::Duration`
- **Duration settings renamed so each one names what it sets** – now that every duration reads the same way, they are named the same way too: a gem-level default is its per-worker setting with `default_` in front, and no name advertises a unit it shares with all the others
  - `Busybee.grpc_retry_delay_ms` → `Busybee.grpc_retry_delay`
  - `Busybee.default_job_lock_timeout` → `Busybee.default_job_timeout`, matching the worker DSL's `job_timeout`
  - `Busybee.default_job_request_timeout` → `Busybee.default_polling_request_timeout`, matching `polling request_timeout:`
  - The worker DSL's `backoff` → `fail_job_backoff`, matching `Busybee.default_fail_job_backoff` and distinguishing it from `backpressure_delay`, which is also a backoff and means something else entirely. The YAML key moves with it; `fail_job(backoff:)` and `job.fail!(backoff:)` are unchanged
- **Testing helper `zeebe_available?(timeout:)` is now `zeebe_available?(wait:)`** – `wait:` is the one parameter name in Busybee that means seconds, and it is reserved for the test helpers that pause your own process. Everything else, including `activate_job(timeout:)` and `publish_message(ttl:)` alongside it, is milliseconds
- **Strict output validation enabled by default** – Workers with `complete_job_on_success` or manual `complete!` calls will raise `Busybee::UndeclaredOutput` if `perform` returns keys not declared as `output`. Add `strict_outputs false` to workers that intentionally return ad-hoc keys

## v0.3.0 (2026-03-13)

Worker Pattern Framework and CLI, with testing helpers and YAML configuration support.

### New Features:

- **Worker Pattern** (`Busybee::Worker`) – Define job handlers as Ruby classes with a clean DSL:
  - Declarative inputs (`variable`, `header`) and outputs with type hints, defaults, and validation
  - Accessor methods for inputs – use `order_id` directly in `perform` instead of `variables[:order_id]`
  - Automatic job completion on success and failure reporting on exception (`complete_job_on_success`, `fail_job_on_error`)
  - Manual lifecycle control via `complete!`, `fail!`, `throw_bpmn_error!` for complex flows
  - Configurable `shutdown_on` for exceptions that should trigger graceful process shutdown (e.g., `PG::ConnectionBad`)
  - Per-worker configuration via DSL (`worker_mode`, `polling`, `streaming`, `job_timeout`, `backoff`, `backpressure_delay`)

- **CLI** (`bundle exec busybee`) – Run workers as long-lived processes:
  - Positional args: `busybee Worker1 Worker2 Worker3`
  - YAML config: `busybee --config config/busybee.yml`
  - Flags: `--worker-mode`, `--log-format`, `--worker-name`, `--cluster-address`
  - Automatic Rails environment loading (skip with `BUSYBEE_SKIP_RAILS=1`)
  - Graceful shutdown on INT/TERM/QUIT; force shutdown on second signal

- **Three Worker Modes:**
  - **Polling** – long-polls the Zeebe gateway for available jobs
  - **Streaming** – persistent gRPC stream for lowest-latency job delivery, with optional in-memory buffer and throttle
  - **Hybrid** (default) – combines streaming with polling to handle both new jobs and pre-existing backlogs while still guaranteeing sequential execution

- **Multiple Workers:** – run multiple worker classes in a single process, each in its own thread with independently-resolved configuration

- **YAML Configuration** – define workers and per-worker configuration in a config file. Top-level settings apply to all workers; per-worker overrides take precedence

- **Worker Testing Helpers:**
  - `execute_worker(WorkerClass, variables: {...})` – run a worker's full lifecycle against a test job without Zeebe
  - `build_test_job(variables: {...})` – construct a test job backed by a stub client for state inspection
  - RSpec matchers: `complete_job(job)`, `fail_job(job)`, `throw_bpmn_error_on(job)` with chainable assertions (`.with_vars`, `.with_error`, `.with_code`)

## v0.2.0 (2026-02-05)

Production-ready Client API with Rails integration.

### New Features:

- **Client Class** (`Busybee::Client`) - a Ruby-idiomatic wrapper around the Zeebe gRPC API:
  - Pluggable authentication with four credential types: `Insecure`, `TLS`, `OAuth`, and `CamundaCloud`
    - Automatic credential type detection from parameters
  - Almost all GRPC operations, including `deploy_process`, `start_instance`, `cancel_instance`, `publish_message`, `broadcast_signal` `set_variables`, `resolve_incident`, `complete_job`, `fail_job`, `throw_bpmn_error`, `update_job_retries`, `update_job_timeout`
  - Two job activation methods: `with_each_job` (long-polling), and `open_job_stream` (continuous stream) with Enumerable wrapper class
  - Rich wrapper class (`Busybee::Job`) for activated jobs:
    - `variables` and `headers` with indifferent access (string or symbol keys)
    - Status tracking (`:ready`, `:complete`, `:failed`) to prevent double-completion
    - Action methods: `complete!`, `fail!`, `throw_bpmn_error!`
  - Variable serialization handles ActiveRecord or other custom objects

- **Rails Integration** - Automatic configuration from `config.x.busybee.*`, works seamlessly with Rails secrets
  - Defaults to using Rails logger
  - Structured logs with a `[busybee]` prefix, supporting text or JSON modes

### Breaking Changes:

- **Testing::Helpers:**
  - Now uses `Busybee.cluster_address` instead of `Busybee::Testing.address`, which has been removed
  - Was refactored for namespace safety and some methods are no longer accessible within specs

## v0.1.0 (2025-12-29)

Initial public release with foundational components for testing BPMN workflows.

### New Features:

- **Testing Module** (`Busybee::Testing`) - RSpec helpers and matchers for testing BPMN workflows against Zeebe:
  - `deploy_process` - Deploy BPMN files with optional unique IDs for test isolation
  - `with_process_instance` - Create process instances with automatic cleanup
  - `activate_job` / `activate_jobs` - Activate jobs for assertions
  - `publish_message` - Trigger message catch events
  - `set_variables` - Update process variables
  - `assert_process_completed!` - Verify workflow completion
  - `ActivatedJob` fluent API with `expect_variables`, `expect_headers`, `and_complete`, `and_fail`, `and_throw_error_event`
  - RSpec matchers: `have_activated`, `have_received_variables`, `have_received_headers`

- **GRPC Layer** (`Busybee::GRPC`) - Generated protocol buffer classes from the Zeebe 8.8 proto definition for direct Zeebe API access

## v0.0.1 (2025-12-03)

- Initial development, not released


