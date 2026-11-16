# Changelog

## Unreleased

Instrumentation hooks for every job, worker and gRPC call, with testing helpers to match, structured logs, and a guide to operating busybee in production.

### New Features:

- **Lifecycle Hooks** – Attach your own code to every moment of a job, a worker and each gRPC call, as middleware or observation, wired into whichever APM or error reporter you run (Datadog, New Relic, Sentry and the like):
  - Job hooks: `on_job_activated`, `around_job_execution`, `on_job_executed`, `on_job_not_executed`; around your own code: `before_perform`, `around_perform`, `after_perform`
  - Worker hooks: `on_worker_started`, `on_worker_stop_requested`, `on_worker_stopping`, `on_worker_shutdown`
  - Call hooks: `before_call`, `around_call`, `after_call`, around every gRPC call
  - Each hook receives a lifecycle object (status, counters, timestamps, durations), with two ready-made projections: `context_tags` for metric labels, `logging_context` for structured logs
  - `perform.call` returns the job's result to every around hook
  - Declare the worker unhealthy from any hook with `raise Busybee::Worker::Shutdown`; `shutdown_on` escalates from job hooks, `Busybee.shutdown_on_errors` from call hooks
  - Any other `StandardError` from an observing hook is logged and swallowed, so one broken observer can't break job processing or shutdown

- **Hook Filters, Checked at Boot** – Register a hook only for the cases you care about, such as failed jobs:
  - Match lifecycle attributes by literal, Regexp, Class, Proc, or an array of them; Strings and Symbols match alike
  - A filter that could never fire is refused at boot, with the reason

- **Call Hooks That Shape the Request** – Rewrite an outbound request in `before_call`, once for every call of its kind: scrub sensitive error messages, adjust retries, add correlation ids:
  - A sent request is sealed, so `after_call` reports exactly what the engine received; retries carry your rewrites
  - A client call from inside a call hook raises `Busybee::ReentrantCall`

- **Perform Hooks That Fire When Your Code Runs** – `before_perform`, `around_perform` and `after_perform` fire only when `perform` is attempted:
  - `after_perform` runs however the attempt turned out, after automatic completion or failure
  - An error from any of the three takes the path an error from `perform` takes

- **Short-Circuit a Job From a Hook** – Resolve a job from any job hook with `complete!`, `fail!` or `throw_bpmn_error!`, and busybee skips `perform`, input validation and automatic completion or failure:
  - Your middleware keeps calling `perform.call` as always; `on_job_activated`, `around_job_execution` and `on_job_executed` still bracket the job
  - Resolving an already-resolved job still raises `Busybee::JobAlreadyHandled`

- **Shutdowns Your Instrumentation Can Count On** – Job and worker brackets close on every graceful shutdown, so gauges stay true across a deploy:
  - `on_job_not_executed` fires for a job handed back unworked; exactly one of it and `on_job_executed` fires per activated job
  - Every worker that starts fires each of the four worker moments exactly once
  - An escalation from `on_worker_stop_requested`, `on_worker_stopping` or `on_worker_shutdown` is recorded on `on_worker_shutdown`'s `status.error` while the shutdown finishes
  - An error arriving once a graceful stop is under way lets that stop finish; one outside `StandardError` makes the `busybee` command exit with status 1
  - A forced stop or an error outside `StandardError` may skip hooks to get out fast

- **Choose What Counts as Backpressure** – `Busybee.backpressure_statuses` (default `[:resource_exhausted]`) names the gRPC statuses that make polling and hybrid workers back off for `backpressure_delay` and retry

- **Tunable Shutdown Waits** – `Busybee.shutdown_wait_timeout` (default 5 seconds) bounds how long a stopping worker waits on its other threads; also `config.x.busybee.shutdown_wait_timeout` and top-level YAML

- **Dropped Connections Can't Stall a Stream** – HTTP/2 keepalive pings surface a silently dropped streaming connection as a recoverable gateway error:
  - On by default; tune with `Busybee.grpc_keepalive_interval` (45 seconds) and `Busybee.grpc_keepalive_timeout` (20 seconds), or set both to `false`

- **Structured Logs** – Every line follows your `log_format` and starts with `[busybee]`, so one parser handles them all:
  - JSON lines carry the `logging_context` of their job, worker or call, an error's `error_class` and `error_message`, and a `time` field
  - Worker starts and stops and job outcomes log at `info`, activations at `debug`
  - A logger that fails to write leaves your workers running and reports on stderr
  - Existing lines were reworded to name their job or worker; check any patterns you match on

- **Durations, Written However Reads Best** – Every duration in configuration, client calls and the worker DSL takes milliseconds as a number, an `ActiveSupport::Duration` (`30.seconds`), or a numeric String for `ENV`-sourced config:
  - Fractions are kept, so `buffer_throttle: 0.1` means what it says
  - A `Duration` reaches the wire and the worker's backoff at its true length

- **A Warning When a Duration Looks Like a Units Slip** – A setting such as `default_message_ttl = 30` logs a warning suggesting `30000` or `30.seconds`, and still applies your value

- **The Client, Right From `perform`** – `client` (delegating to `job.client`) makes any other gRPC call from inside your worker

- **Strict Output Validation** – A worker's outputs must match its `output` declarations; an undeclared key raises `Busybee::UndeclaredOutput`:
  - Opt out with `strict_outputs false` per worker or `Busybee.default_strict_outputs = false`
  - On by default (see Breaking Changes)

- **Testable Hooks** – Put every hook you register under test, with no Zeebe and no network:
  - `execute_worker` runs your worker's full lifecycle, so its hooks fire in production order
  - `fire_busybee_hooks` fires one moment's hooks, filters included; `without_busybee_hooks` (or `without_busybee_hooks:` metadata) subtracts them; `isolate_busybee_hooks` keeps a spec's registrations from leaking
  - `start_test_worker` holds a worker open to test its lifecycle
  - `build_test_client` is a real `Busybee::Client` with an in-process transport: program the gateway with `client.on`, read what was sent with `client.received`
  - `build_test_worker_status` and `build_test_call` build the other carriers; `build_test_job` adds `worker_class:`, `worker_status:`, `source:`, `buffered:`, `status:` and `key:`

- **Wait for Every Job a Step Creates** – `activate_jobs(type, expected: 3)` waits until all three are in hand, so no `sleep` before activating:
  - `max_jobs:` succeeds with fewer, none included
  - Shortfalls raise `Busybee::Testing::NoJobsAvailable` (formerly `NoJobAvailable`, which still works), under a new `Busybee::Testing::Error` base

- **A Guide to Operating Busybee** – `docs/operating.md` covers logs, exit statuses, shutdown timing, health probes and troubleshooting for the `busybee` command

- **Docs for the Version You Run** – The RubyGems page links the docs for your installed version (`documentation_uri`); the gem no longer ships them

### Bug Fixes:

- **Workers Survive Gateway Backpressure** – `RESOURCE_EXHAUSTED` no longer crashes a polling or hybrid worker and its siblings; it arrives as a `Busybee::GRPC::Error`, and the worker backs off and retries
  - `Client#with_each_job` raises `Busybee::GRPC::Error` for every gateway status, as documented
- **Backoff and Retry Delays Wait the Length You Configured** – `backpressure_delay` waits milliseconds, not seconds; `grpc_retry_delay` and `buffer_throttle` honor a `Duration`; a sub-second `Duration` no longer rounds to zero
- **Extending a Job's Lock in a Test Accepts a Duration** – The testing module's `update_timeout(5.minutes)` asks for five minutes
- **Job Matchers Accept a Regexp or Any Matcher** – In `have_received_variables` and `have_received_headers`
- **Workflow Tests Leave No Instance Behind, Nested or Not** – Each `with_process_instance` cancels its own instance and restores the outer one; `assert_process_completed!` outside one raises `Busybee::Testing::NoCurrentProcessInstance`
- **`not_to have_available_jobs` No Longer Passes on an Error** – Only `NoJobsAvailable` counts as no jobs; any other error raises through
- **A Failing Worker Can No Longer Take a Container Down Quietly** – A worker dying of an error outside `StandardError` in a multi-worker process is logged, stops its siblings and ends the process
- **A Deploy's Shutdown Stays Graceful** – A gateway error or unhealthy declaration during a stop is logged and reported to `on_worker_shutdown`, not raised as a crash; a backpressure backoff ends when a stop arrives
- **A Streaming Worker Stops Even While It Connects** – A stop that arrives while the job stream opens takes effect at once
- **An Unreachable Gateway Reads as a Gateway Error** – `Client#open_job_stream` raises `Busybee::GRPC::Error`, and the worker stops as `:gateway_error`
- **A Worker Whose Stream Ends Takes the Process Down With It** – In a multi-worker process, the others stop too, so your orchestrator replaces the process
- **A Forced Shutdown Says What It Threw Away** – The forced stop behind a second termination signal logs how many buffered jobs it dropped
- **Rails Settings Apply Whichever Loads First** – The Railtie loads whether busybee or Rails is required first; set `config.x.busybee` in `config/application.rb` or `config/environments/*.rb`, not an initializer
- **Rails Config No Longer Overwrites Settings It Doesn't Mention** – Including `cluster_address`, `worker_name` and a logger set before Rails boots (`nil` included); a blank value counts as unset
- **A Rails App That Fails to Boot Stops the `busybee` Command** – It logs why and exits with status 1; `busybee` logs from its first line, to stdout until your app's logger takes over
- **Empty Environment Variables Count as Unset** – `CLUSTER_ADDRESS`, `BUSYBEE_WORKER_NAME`, `BUSYBEE_CREDENTIAL_TYPE`, the credential variables and `BUSYBEE_SKIP_RAILS`
- **A Configured Cluster Address Wins Over `CLUSTER_ADDRESS`** – `Busybee.cluster_address` or `--cluster-address` takes precedence; `CLUSTER_ADDRESS` still applies when neither is set

### Breaking Changes:

- **Strict Output Validation Is On by Default** – Undeclared output keys raise `Busybee::UndeclaredOutput`; declare them, or add `strict_outputs false`
- **`job.complete!` Checks Required Outputs From Inside a Worker** – A missing required output raises `Busybee::MissingOutput`
- **`fail_job_on_error` Is Gone: Every Failure Is Reported** – The declaration raises `NoMethodError` at load; to resolve a failure your way, rescue inside `perform`
- **Duration Settings Renamed So Each One Names What It Sets**:
  - `Busybee.grpc_retry_delay_ms` → `Busybee.grpc_retry_delay`
  - `Busybee.default_job_lock_timeout` → `Busybee.default_job_timeout`
  - `Busybee.default_job_request_timeout` → `Busybee.default_polling_request_timeout`
  - Worker DSL and YAML `backoff` → `fail_job_backoff`
- **Accepted Configuration Values Have One Home** – `Busybee::VALID_*`, `Busybee::RuntimeConfig::VALID_*` and `Busybee::Worker::Configuration::VALID_WORKER_MODES` → `Busybee::Configure::VALID_CREDENTIAL_TYPES`, `VALID_LOG_FORMATS`, `VALID_WORKER_MODES`, all Symbols
- **`busybee` Flags Give Way to Your App's Own Configuration** – `--cluster-address`, `--worker-name` and `--log-format` apply only where your app sets nothing
- **Testing Helpers Go Only Where You Ask for Them** – Tag specs `:busybee`, or include `Busybee::Testing::Helpers` everywhere yourself
- **Workflow Tests Work Only Their Own Instance's Jobs** – Other instances' jobs are handed back; accept them with `busybee_foreign_jobs: :accept` or `Busybee::Testing.accepting_foreign_jobs`
- **`activate_jobs` Activates Once, When You Call It, and Returns an Array** – Not an Enumerator; `max_jobs:` takes only a positive Integer
- **`assert_process_completed!` Raises `Busybee::Testing::ProcessStillRunning`** – Instead of `RuntimeError`
- **`have_activated` Is Gone** – Use `activate_job(...).expect_variables(...).and_complete(...)`
- **`build_test_job` Hands Back a Real Job, and a Real Client With It** – A genuine `ActivatedJob` that validates field types; pass `client:` to supply your own
- **`execute_worker` Hands Back the Job** – `perform`'s return value is on `job.result`, a failure's error on `job.error`; your hooks fire too
- **Testing Helpers Keep Their Own Timings** – `Busybee::Testing::ACTIVATE_JOB_TIMEOUT_MS`, `ACTIVATE_JOB_LOCK_MS` and `PUBLISH_MESSAGE_TTL_MS`, no longer `Busybee.default_polling_request_timeout`
- **Testing Helper `publish_message` Parameters Renamed** – `variables:` → `vars:`, `ttl_ms:` → `ttl:`
- **Testing Helper `zeebe_available?(timeout:)` Is Now `zeebe_available?(wait:)`** – In seconds

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


