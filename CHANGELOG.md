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

- **Short-Circuit a Job From a Hook** – sometimes the right answer is "don't do this work": the job was already fulfilled by an earlier attempt, the downstream service is in a known outage, the tenant is paused for maintenance. Resolve the job from any job hook — `complete!`, `fail!`, `throw_bpmn_error!` — and busybee stands down. `perform` doesn't run, input validation doesn't run, and neither automatic completion nor automatic failure fires against a job the engine already considers finished. Keep calling `perform.call` from your middleware exactly as you always have: the chain always descends, and busybee skips the work for you
  - The perform-family hooks stand down with it — `before_perform`, `around_perform` and `after_perform` fire exactly when `perform` is attempted — while `on_job_activated`, `around_job_execution` and `on_job_executed` bracket every job that reached your process, short-circuited or not, so your instrumentation still sees it happen
  - A skipped `perform` is logged at `info`, and `complete!` now tells you when variables you passed were discarded in favour of a result `perform` had already returned

### Bug Fixes:

- **Workers Survive Gateway Backpressure** – a gateway reporting `RESOURCE_EXHAUSTED` to a polling or hybrid worker used to crash it, and in a multi-worker process took every sibling worker down with it — so a fleet-wide broker slowdown became a fleet-wide outage. Job activation is a server-streaming call whose status arrives while responses are being read, and that error was escaping untranslated past the very rescue meant to catch it. It now reaches the worker as a `Busybee::GRPC::Error` with `grpc_status` intact, so the documented backoff-and-retry runs and the process stays up
  - `Client#with_each_job` now keeps the `Busybee::GRPC::Error` contract its documentation promises, whatever status the gateway returns

- **Backoff and Retry Delays Wait the Length You Configured** – three settings were measured in milliseconds on the way in and then slept as though they were something else, so none of them waited what you asked for:
  - `backpressure_delay` parked a worker for its value in **seconds**: the default of `2_000` meant a worker vanished for over half an hour on a single backpressure event, and the documented `10_000` example for nearly three hours. It now waits two seconds
  - `grpc_retry_delay` and `buffer_throttle` had the opposite fault, and only when set with an `ActiveSupport::Duration`: `grpc_retry_delay = 0.5.seconds` retried after half a *millisecond*. Both now honour a `Duration` exactly as they honour a number
  - A sub-second `Duration` no longer rounds to zero on its way to a wait, so `0.25.seconds` means a quarter second rather than no pause at all

- **Extending a Job's Lock in a Test Accepts a Duration** – the testing module's `update_timeout` read an `ActiveSupport::Duration` as a bare number, so `job.update_timeout(5.minutes)` asked the engine for 300 *milliseconds* and the lock lapsed immediately. It now reads a length of time the way everything else in the gem does

- **Error Handling No Longer Depends on Who Happens to Be Listening** – whether an error was suppressed, raised, or escalated to a graceful shutdown could change depending on whether any hook was registered, because a chain assembled from no hooks carried no error policy at all:
  - An error you named in `shutdown_on` that escaped the worker's own handling stopped the process as an unexplained crash — `reason: :crash` rather than the `:unhealthy` you declared — unless some unrelated hook happened to be registered to hold the policy open. (Errors raised by `perform` itself were always escalated correctly.) `shutdown_on` now holds wherever the error comes from
  - An error busybee itself could not handle was swallowed and logged as `Error in hooks (ignored)`, blaming your instrumentation for a fault in the gem and pointing you at a source location in your worker. Such errors now travel, so a defect surfaces where it happened instead of being absorbed by the machinery that noticed it
  - `safe:` describes what happens when a *hook* raises, and nothing more. What becomes of an error raised by the work a hook wrapped is the job's business, or the caller's — see "What the Swallow Doesn't Cover" in the hooks guide for reading an outcome off the carrier rather than rescuing around the call

### Breaking Changes:

- **`after_perform` now fires whenever `perform` was attempted** – previously it also required that the job had settled, so it stayed silent on exactly the occasions you most want to hear about: a resolution call that never reached the engine, or a `perform` that handed the work to a background thread. It is now an `ensure` on your code — it runs however the attempt turned out, still after automatic completion and failure, so `status` and `error` are already on the job when you read them. A job arriving with `status == :ready` is still yours to settle, and you can resolve it from the hook. Registrations filtered to a settled outcome — `status: :complete`, `:failed`, `:error` — behave exactly as before, since every newly-reached case is `:ready`
- **`after_perform` hooks filtered by `error:` will fire more often** – calling this out separately because it is the one filter the change above widens. The newly-reached cases carry the error that stopped the resolution — typically a `Busybee::GRPC::Error` from a failed `complete_job` or `fail_job` — so a hook registered as `after_perform(error: SomeError)` now sees transport failures it never used to. If that hook assumes the job settled, give it a `job.resolved?` check
- **Errors from `after_perform` propagate instead of being swallowed** – it joins `before_perform` and `around_perform`, so the whole perform family now behaves the same way. An error raised there takes the same path as one raised by `perform` itself: if the job is still unresolved, it fails the job and the engine is told; if the job already settled, it is logged against the job rather than re-resolving it; and `shutdown_on` still escalates. This is what makes an invalid output offered from a hook reach the engine rather than vanishing
- **`job.complete!` validates outputs like `worker.complete!` always has** – the two used to differ, so resolving through the job silently skipped the `output` declarations that resolving through the worker enforced — a trap that got sharper now that a hook can resolve a job. Validation is the worker's contract, so it applies whenever a worker is attached to the job, which is every job your worker is processing, and is skipped when there is none, leaving `Busybee::Job` usable on its own. If you were relying on `job.complete!` to bypass validation, declare the keys or set `strict_outputs false`
- **`fail_job_on_error` is gone — reporting a failure is no longer optional** – every exception that escapes `perform` is now reported to the workflow engine. Switching that off left the job silently unresolved, and because a lease expiring doesn't spend a retry, a job that failed the same way every time looped indefinitely and never raised an incident for anyone to see. A worker still carrying the declaration raises `NoMethodError` when it loads, so you hear about it at boot rather than in production. To report a failure *your* way, rescue inside `perform` and resolve the job yourself — `fail!(e, retries: job.retries)` to come back without spending the budget, `throw_bpmn_error!` for an outcome your process model has a path for — and whatever your rescue doesn't catch is still reported for you, which is the point. To take the worker process down on a class of errors instead, use `shutdown_on`. To reshape what reaches the engine across every worker — redacting sensitive text out of error messages, say — a call hook is the place. One misleading warning retires alongside it: Busybee no longer tells you a job "will timeout and retry" when it had in fact already been completed
- **`Busybee::StatusChangeOutsidePerform` no longer exists** – resolving a job from a hook used to raise it. That is now a supported way to short-circuit a job (see Short-Circuit a Job From a Hook, above). Resolving a job that is *already* resolved still raises `Busybee::JobAlreadyHandled`, which was always the more accurate answer. Remove any `rescue Busybee::StatusChangeOutsidePerform` — the constant is gone, and code referencing it will raise `NameError`
- **`after_perform` no longer fires when `perform` didn't run** – it now requires both that the job settled *and* that `perform` was attempted, so a job short-circuited by a hook or turned away by input validation no longer reaches it. This keeps the perform-family hooks honest to their name: they fire exactly when your code was given a chance to run. `on_job_executed` fires for every job that reached your process either way, and is where observation that must not miss one belongs
- **Middleware can no longer cancel a job by skipping its yield** – an `around_perform` that returns without calling `perform.call` now runs the rest of the chain anyway and logs a warning, which is what `around_job_execution` has always done. Skipping the work is a decision worth making explicitly: resolve the job instead
- **Testing helper `publish_message` parameters renamed** – `variables:` is now `vars:` and `ttl_ms:` is now `ttl:` to match `Client#publish_message` naming. `ttl:` now accepts both Integer (milliseconds) and `ActiveSupport::Duration`
- **Duration settings renamed so each one names what it sets** – now that every duration reads the same way, they are named the same way too: a gem-level default is its per-worker setting with `default_` in front, and no name advertises a unit it shares with all the others
  - `Busybee.grpc_retry_delay_ms` → `Busybee.grpc_retry_delay`
  - `Busybee.default_job_lock_timeout` → `Busybee.default_job_timeout`, matching the worker DSL's `job_timeout`
  - `Busybee.default_job_request_timeout` → `Busybee.default_polling_request_timeout`, matching `polling request_timeout:`
  - The worker DSL's `backoff` → `fail_job_backoff`, matching `Busybee.default_fail_job_backoff` and distinguishing it from `backpressure_delay`, which is also a backoff and means something else entirely. The YAML key moves with it; `fail_job(backoff:)` and `job.fail!(backoff:)` are unchanged
- **Testing helper `zeebe_available?(timeout:)` is now `zeebe_available?(wait:)`** – `wait:` is the one parameter name in Busybee that means seconds, and it is reserved for the test helpers that pause your own process. Everything else, including `activate_job(timeout:)` and `publish_message(ttl:)` alongside it, is milliseconds
- **Strict output validation enabled by default** – Workers with `complete_job_on_success` or manual `complete!` calls will raise `Busybee::UndeclaredOutput` if `perform` returns keys not declared as `output`. Add `strict_outputs false` to workers that intentionally return ad-hoc keys
- **Testing helpers keep their own timings instead of reading your configuration** – `activate_job` and `activate_jobs` waited for `Busybee.default_polling_request_timeout`, so a suite inherited whatever long-poll you had sized for production, and a spec looking for a job that was never coming sat through the whole minute. Waiting is now the harness's own call — `Busybee::Testing::ACTIVATE_JOB_TIMEOUT_MS` (5 seconds), alongside `ACTIVATE_JOB_LOCK_MS` (30 seconds) and `PUBLISH_MESSAGE_TTL_MS` (5 seconds) — so no test environment has to override production settings to get sensible test behavior. Every one is still overridable per call; pass `timeout:` where an example genuinely needs to wait longer

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


