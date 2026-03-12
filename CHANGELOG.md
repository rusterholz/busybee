# Changelog

## v0.3.0 (2026-03-06)

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


