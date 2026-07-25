# Job Execution Flows

Maintainer-facing reference tracing every salient moment in a job's execution from gRPC receive to runner-return. The document is organized into two top-level sections: **Typical Lifecycle** covers the four normal-operation variants (auto-complete, manual complete, autofail, manual fail / BPMN error), and **Lifecycle Edge Cases** covers the unusual paths (`Busybee::Shutdown` propagation, `StatusChangeOutsidePerform` flag-catches, GRPC call failures, and serious non-StandardError exceptions). Each variant is presented in two paired formats: a condensed at-a-glance summary, followed by a step-by-step walkthrough.

## Notation

Short forms in this document use compact line-per-moment notation. Each line is either a labeled flag (`GRPC`, `TIMESTAMP`, `HOOK`, `MIDDLEWARE`, `VALIDATION`, `STATUS CHANGE`) marking a category of user-facing salience, or a `-- text --` item marking an uncategorized point of interest. Error-semantic annotations on safe/unsafe hooks and middleware:

- `(safe)` — errors are logged and swallowed (`run` safe-mode).
- `(safe*)` — post-resolution period; errors propagate but the resolution stands and the lifecycle continues to ensure-block hooks.
- `(unsafe)` — errors propagate; uncaught errors in Variants A/B trigger autofail (Variant C).

Long forms walk the same lifecycle in narrative + code-reference detail, organized into numbered steps. Step numbering is shared across variants: every variant starts at step 8 (the branch point), since steps 1–7 are the common preamble.

## Typical Lifecycle

The four variants of normal operation: Variant A (auto-complete, the happy path), Variant B (manual `complete!` mid-perform), Variant C (autofail when perform raises a `StandardError`), and Variant D (manual `fail!` / `throw_bpmn_error!` mid-perform). The common preamble (steps 1–7) applies to all four; the branch point is `instance.perform`, after which each variant continues from step 8.

### Common Preamble (1–7)

These seven steps run before the branch point and apply to all four variants.

**At a glance:**

```
GRPC: job yielded (engine sees it as activated)
TIMESTAMP: activated_at
HOOK: on_job_activated (safe)
-- possible buffer delay (streamed/buffered runners) --
MIDDLEWARE: around_job_execution start (safe)
TIMESTAMP: execution_started_at
VALIDATION: required inputs (unsafe)
-- status changes prevented --
HOOK: before_perform (unsafe)
MIDDLEWARE: around_perform start (unsafe)
-- status changes allowed --
TIMESTAMP: perform_started_at
-- instance.perform starts --
```

**Walkthrough:**

1. GRPC CALL: A job is yielded from the workflow engine at one of the Runner receive points: `Polling#process_all_available_jobs`, `Streaming#run_inline`, `Streaming#pump_stream_into_buffer`, or `Hybrid#drain_backlog_while_also_processing_buffer`. At this point the workflow engine has marked the job activated.
2. `Runner#activate_job(job, source:, buffer_size:)`:
   - TIMESTAMP: `activated_at`.
   - `job.set_context(source:, buffer_size:, worker_class:)` — routes through Job's typed POROs; `source`/`buffer_size`/`worker_class` land on `Activation`.
   - HOOKS: `on_job_activated` (safe — errors are logged and swallowed).
3. If the receive point is `Streaming#pump_stream_into_buffer`, the pump thread pushes the job onto `@job_buffer` and a consumer thread pops it. The Job carries all its state (POROs, timestamps, status) across the thread boundary.
4. `Runner#execute_job(job)`:
   - HOOKS: `around_job_execution` middleware, portions before yield (safe — errors are logged and swallowed; downstream still runs via the called-flag pattern in `Chain.build_safe`).
5. `Worker.perform_job(job)` (inside the core of the `around_job_execution` chain):
   - TIMESTAMP: `execution_started_at`.
   - `job.set_context(worker: instance)` — captures the worker instance on `Activation` so hooks can see it.
6. `run_hooked_perform(instance)`:
   - VALIDATION: required inputs (errors here propagate, jumping to Variant C and failing the job).
   - FLAG SET: `Job#_prevent_status_changes!`. Any `complete!`/`fail!`/`throw_bpmn_error!` while this flag is set raises `StatusChangeOutsidePerform`.
   - HOOKS: `before_perform` (unsafe — errors propagate, jump to Variant C, and fail the job, as if they were from inside perform).
   - HOOKS: `around_perform` middleware, portions before yield (unsafe — errors propagate, jump to Variant C, and fail the job).
7. Inside the `around_perform` middleware chain core:
   - FLAG CLEARED: `Job#_allow_status_changes!`. Status changes are allowed during perform.
   - `timed_perform(instance)`:
     - TIMESTAMP: `perform_started_at`.
     - `instance.perform` runs — **this is the branch point.**

### Variant A — Auto-Complete (Happy Path)

At the branch point, `instance.perform` exits normally, returning a Hash (or anything else; non-Hash return values are coerced to `{}` later in `handle_success`).

**At a glance:**

```
-- instance.perform returns --
TIMESTAMP: perform_finished_at
-- status changes prevented --
-- result captured to Job --
MIDDLEWARE: around_perform finish (unsafe)
-- status changes allowed --
VALIDATION: required outputs (unsafe)
VALIDATION: undeclared outputs (unsafe)
GRPC: job completed (engine sees it as completed)
TIMESTAMP: resolved_at
STATUS CHANGE: -> complete
HOOK: after_perform (safe)
MIDDLEWARE: around_job_execution finish (safe)
TIMESTAMP: executed_at
HOOK: on_job_executed (safe)
```

**Walkthrough:**

A8. Continuing the `around_perform` middleware chain core:
  - Continuing `timed_perform(instance)`:
    - TIMESTAMP: `perform_finished_at` (stamped in `timed_perform`'s ensure as perform exits — fires regardless of how perform exits, so this same step happens in every variant).
  - FLAG SET: `Job#_prevent_status_changes!` — re-engaged in the core block's ensure. After-yield `around_perform` middleware cannot resolve the job (would raise `StatusChangeOutsidePerform`).
  - `capture_chain_result(target, raw_result)` (the innermost wrapper around the core block):
    - `resolution.set_result(raw_result)` — set-once, accepts only Hash values; coerces to a frozen `HashWithIndifferentAccess`. **Result is now set.** Non-Hash perform return values are silently rejected here and end up as `nil` on the Job (and `{}` in `handle_success`).

A9. Continuing `run_hooked_perform`:
  - HOOKS: Continuing `around_perform` middleware, portions after yield (unsafe — errors propagate, jump to Variant C, and fail the job).
  - FLAG CLEARED: `Job#_allow_status_changes!` — required because `handle_success` is about to call `job.complete!`.

A10. `handle_success(job, result, configuration)`:
  - Exits early if `complete_job_on_success` is off or the job is no longer `ready?` (the latter can't happen in Variant A, but the guard exists for unified handling across variants).
  - VALIDATION: required outputs (errors propagate, jump to Variant C, fail the job).
  - VALIDATION: undeclared outputs (errors propagate, jump to Variant C, fail the job).

A11. `job.complete!(result)`:
  - `resolution.set_result(vars)` — silent no-op (set-once; already set in A8).
  - GRPC CALL: `client.complete_job(key, vars: resolution.result || {})`. **Workflow engine now sees the job as completed.**
  - `resolve!(:complete)`:
    - TIMESTAMP: `resolved_at`.
    - STATUS CHANGE: `Resolution#resolve_to(:complete)` → `@status = :complete` (fire-once enforced).

A12. Continuing `Worker.perform_job(job)`:
  - perform_job's ensure block:
    - HOOKS: `after_perform` via `Hooks.run(:after_perform, job, safe: true)` (safe — errors are logged and swallowed). Fires because `job.resolved?` is true.

A13. Continuing `Runner#execute_job(job)`:
  - HOOKS: Continuing `around_job_execution` middleware, portions after yield (safe — errors are logged and swallowed).
  - execute_job's ensure block:
    - `refresh_buffer_size!(job)` — updates `buffer_size` on `Activation` to the runner's current queue depth. No-op for unbuffered jobs (polling, `Streaming#run_inline`) and for runners without a buffer.
    - TIMESTAMP: `executed_at`.
    - HOOKS: `on_job_executed` via `Hooks.run(:on_job_executed, job, safe: true)` (safe).

Runner continues to the next job.

### Variant B — Manual Complete

At the branch point, `instance.perform` runs user code which calls `complete!(result)` (delegated through `Worker#complete!`).

**At a glance:**

```
-- instance.perform calls complete!(result) --
VALIDATION: required outputs (unsafe)
VALIDATION: undeclared outputs (unsafe)
-- result captured to Job --
GRPC: job completed (engine sees it as completed)
TIMESTAMP: resolved_at
STATUS CHANGE: -> complete
-- remainder of instance.perform runs; return value ignored (safe*) --
TIMESTAMP: perform_finished_at
-- status changes prevented --
MIDDLEWARE: around_perform finish (safe*)
-- status changes allowed --
HOOK: after_perform (safe)
MIDDLEWARE: around_job_execution finish (safe)
TIMESTAMP: executed_at
HOOK: on_job_executed (safe)
```

**Walkthrough:**

B8. `Worker#complete!(result)`:
  - VALIDATION: required outputs (errors propagate, jump to Variant C, fail the job).
  - VALIDATION: undeclared outputs (errors propagate, jump to Variant C, fail the job).
  - Calls `job.complete!(vars)`.

B9. `job.complete!(result)`:
  - `resolution.set_result(vars)` — set-once, accepts only Hash values; coerces to a frozen `HashWithIndifferentAccess`. **Result is now set.**
  - GRPC CALL: `client.complete_job(key, vars: resolution.result || {})`. **Workflow engine now sees the job as completed.**
  - `resolve!(:complete)`:
    - TIMESTAMP: `resolved_at`.
    - STATUS CHANGE: `Resolution#resolve_to(:complete)` → `@status = :complete` (fire-once enforced).

B10. Continuing `instance.perform`:
  - Any portion after `complete!(result)` (return value is ignored; errors here are safe because the job is already complete — they propagate to `perform_job`'s rescue, get logged as post-resolution via `log_post_resolution_error`, and the lifecycle continues at B13 below).

B11. Continuing the `around_perform` middleware chain core:
  - Continuing `timed_perform(instance)`:
    - TIMESTAMP: `perform_finished_at`.
  - FLAG SET: `Job#_prevent_status_changes!` — re-engaged in the core block's ensure.
  - `capture_chain_result(target, raw_result)`:
    - `resolution.set_result(raw_result)` — silent no-op (set-once; already set in B9). The raw perform return value is discarded.

B12. Continuing `run_hooked_perform`:
  - HOOKS: Continuing `around_perform` middleware, portions after yield (safe in this variant because the job is already complete — errors propagate to `perform_job`'s rescue, get logged as post-resolution, and the lifecycle continues at B13 below).
  - FLAG CLEARED: `Job#_allow_status_changes!`.
  - `handle_success(job, result, configuration)` exits early (no-op) because `!job.ready?`.

B13. Continuing `Worker.perform_job(job)`:
  - perform_job's ensure block:
    - HOOKS: `after_perform` via `Hooks.run(:after_perform, job, safe: true)` (safe — errors are logged and swallowed). Fires because `job.resolved?` is true.

B14. Continuing `Runner#execute_job(job)`:
  - HOOKS: Continuing `around_job_execution` middleware, portions after yield (safe — errors are logged and swallowed).
  - execute_job's ensure block:
    - `refresh_buffer_size!(job)` — updates `buffer_size` on `Activation` to the runner's current queue depth. No-op for unbuffered jobs (polling, `Streaming#run_inline`) and for runners without a buffer.
    - TIMESTAMP: `executed_at`.
    - HOOKS: `on_job_executed` via `Hooks.run(:on_job_executed, job, safe: true)` (safe).

Runner continues to the next job.

### Variant C — Auto-Fail (Perform Raises)

At the branch point, `instance.perform` raises some subclass of `StandardError`. This variant can also be reached from any of the "errors propagate, jump to Variant C" points elsewhere in the lifecycle: Common preamble (step 6: `validate_inputs!`, `before_perform`, `around_perform` middleware pre-yield), Variant A (A9: `around_perform` middleware post-yield; A10: `handle_success` output validations), and Variant B (B8: `Worker#complete!` output validations). **All secondary entry points land at step C10 — `perform_job`'s rescue is the common catch point; C8 and C9 describe the primary case where the error unwinds through `timed_perform` and the `around_perform` chain.**

**At a glance:**

```
-- instance.perform raises StandardError --
TIMESTAMP: perform_finished_at
-- status changes prevented --
-- around_perform middleware post-yield NOT run --
-- status changes allowed --
-- error captured to Job (early in handle_perform_exception) --
-- autofail attempted (if fail_job_on_error and ready?) --
GRPC: job failed (engine sees it as failed)
TIMESTAMP: resolved_at
STATUS CHANGE: -> failed
HOOK: after_perform (safe, conditional on resolved?)
MIDDLEWARE: around_job_execution finish (safe)
TIMESTAMP: executed_at
HOOK: on_job_executed (safe)
```

**Walkthrough:**

C8. Continuing the `around_perform` middleware chain core:
  - Continuing `timed_perform(instance)`:
    - TIMESTAMP: `perform_finished_at` (stamped in `timed_perform`'s ensure regardless of how perform exited).
  - FLAG SET: `Job#_prevent_status_changes!` — re-engaged in the core block's ensure.
  - The error propagates past `capture_chain_result` (the innermost wrapper around the core block); no result is captured.
  - The error propagates through the chain: portions of `around_perform` middleware after yield **do not get run** (around_perform uses propagating semantics, not safe — errors short-circuit the rest of the chain).

C9. Continuing `run_hooked_perform`:
  - The error propagates through; the post-chain `Job#_allow_status_changes!` clear and the `handle_success` call do not run.

C10. Continuing `Worker.perform_job(job)`:
  - The error is rescued by `perform_job`'s `rescue StandardError`.
  - `handle_perform_exception(job, exception)`:
    - FLAG CLEARED: `Job#_allow_status_changes!` (necessary because we're about to autofail the job).
    - EARLY ERROR CAPTURE: `resolution.set_error(underlying_error(exception))` — records the error on the error axis of Resolution before autofail runs, so `after_perform` sees the error attached to the Job even when autofail is disabled (C11) or its GRPC fails (C12). `underlying_error` unwraps a `Shutdown` to its `cause` when applicable.
    - Calls `handle_failure(job, exception, configuration)`.

C11. `handle_failure(job, error, configuration)`:
  - Exits early (no-op) if `fail_job_on_error` is off (autofail disabled — the original error surfaces in C13 via `log_unhandled_error`).
  - Exits early if the job is no longer `ready?` — reachable from the multi-variant interactions where Variant B's `complete!` or Variant D's `fail!`/`throw_bpmn_error!` succeeded before `instance.perform` raised. Logs inline via `log_post_resolution_error` and returns (no surfacing in C13 for this case).
  - Otherwise calls `attempt_auto_fail(job, error, configuration)`.

C12. `attempt_auto_fail(job, error, configuration)` → `job.fail!(underlying_error(error), backoff: configuration.backoff)`:
  - `underlying_error` extracts a Shutdown's `cause` (or returns the error itself) so the engine sees the real failure cause, not the Shutdown wrapper. See **E5** for the full unwrap callout and **E3** for the inverse direction (where the Shutdown wrap is created in the first place).
  - Inside `fail!`: `resolution.set_error({error: ...})` — no-op (set-once on the error axis; already set by C10's early capture).
  - GRPC CALL: `client.fail_job(key, message, retries: nil, backoff: backoff)`. **Workflow engine now sees the job as failed.**
  - `resolve!(:failed)`:
    - TIMESTAMP: `resolved_at`.
    - STATUS CHANGE: `Resolution#resolve_to(:failed)` → `@status = :failed` (fire-once enforced).
  - If `job.fail!` itself raises (e.g., the fail-job GRPC also fails), `attempt_auto_fail` catches and logs the warning; execution continues normally back into `handle_perform_exception`. The error is still attached to the Job via C10's early capture.

C13. Continuing `handle_perform_exception`:
  - Re-raises if exception is `Busybee::Worker::Shutdown` or `Busybee::StatusChangeOutsidePerform` (both are special-cased to propagate past `perform_job`).
  - Wraps in `Shutdown.new(worker: self)` and raises if exception matches `shutdown_on` (per-worker or gem-level shutdown classes).
  - Otherwise: if `fail_job_on_error` is off, `log_unhandled_error(job, exception)` (this is where the early-return from C11's first case surfaces — the original error is recorded in the log).

C14. Continuing `Worker.perform_job(job)`:
  - perform_job's ensure block:
    - FLAG CLEARED: `Job#_allow_status_changes!` (defensive, in case a non-StandardError exception escaped past `rescue StandardError`).
    - HOOKS: `after_perform` via `Hooks.run(:after_perform, job, safe: true)` (safe — errors are logged and swallowed). Fires when `job.resolved?` — true if `attempt_auto_fail` succeeded, false if autofail was skipped (C11) or its GRPC also failed (C12). When `:ready`, the Job still carries the error captured in C10; per-attempt observability for the unresolved case is `on_job_executed` at C15 (runner-level, unconditional). after_perform's contract is "the lifecycle reached a settled outcome the engine has on file."

C15. Continuing `Runner#execute_job(job)`:
  - If `perform_job` re-raised (or wrapped) a `Shutdown` in C13, it propagates through the `around_job_execution` chain. The chain is `safe: true`, but `Chain.build_safe` re-raises `Shutdown` specifically (per chain.rb:45–46), so the Shutdown bubbles out of `Runner#execute_job` after the ensure block completes.
  - Otherwise: HOOKS: Continuing `around_job_execution` middleware, portions after yield (safe — errors are logged and swallowed).
  - execute_job's ensure block (runs regardless of whether Shutdown bubbled):
    - `refresh_buffer_size!(job)` — updates `buffer_size` on `Activation` to the runner's current queue depth. No-op for unbuffered jobs (polling, `Streaming#run_inline`) and for runners without a buffer.
    - TIMESTAMP: `executed_at`.
    - HOOKS: `on_job_executed` via `Hooks.run(:on_job_executed, job, safe: true)` (safe).

If a Shutdown was raised in C13 (re-raised or wrapped), it bubbles up to the Runner after C15's ensure and begins terminating the runner. Otherwise, Runner continues to the next job.

### Variant D — Manual Fail

At the branch point, `instance.perform` runs user code that calls `fail!(error)` or `throw_bpmn_error!(code_or_exception, message)` (both are delegated through `Worker` directly to `Job` — no Worker-level intervention, in contrast to `complete!`'s output-validation step). The `throw_bpmn_error!` flow is identical to `fail!` below except for the GRPC call (`throw_bpmn_error` instead of `fail_job`), the resulting status (`:error` instead of `:failed`), and the error_data shape (`{error_code: code, error_message: message}` plus `{error: exception}` when an Exception is passed).

**At a glance:**

```
-- instance.perform calls fail!(error) --
-- error captured to Job --
GRPC: job failed (engine sees it as failed)
TIMESTAMP: resolved_at
STATUS CHANGE: -> failed
-- remainder of instance.perform runs; Hash return value captured to Job.result (safe*) --
TIMESTAMP: perform_finished_at
-- status changes prevented --
MIDDLEWARE: around_perform finish (safe*)
-- status changes allowed --
HOOK: after_perform (safe)
MIDDLEWARE: around_job_execution finish (safe)
TIMESTAMP: executed_at
HOOK: on_job_executed (safe)
```

For the `throw_bpmn_error!` variant, substitute `GRPC: job error (throw_bpmn_error, engine sees it as terminated by BPMN error)` and `STATUS CHANGE: -> error` in the lines above.

**Walkthrough:**

D8. `job.fail!(error)`:
  - `check_status_change_allowed!(:fail)` — passes (flag is cleared during perform).
  - `ready?` check — passes.
  - `message = format_error_message(error)` (formats Exception → `"[ClassName] message (caused by: ...)"`; strings pass through).
  - `resolution.set_error(error_data)` — error_data is `{error: exception}` for Exception args or `{error_message: string}` for non-Exception args. **Captures the error to Resolution before the GRPC, so the data is on Job even if the GRPC fails.**
  - GRPC CALL: `client.fail_job(key, message, retries: nil, backoff: nil)`. **Workflow engine now sees the job as failed.**
  - `resolve!(:failed)`:
    - TIMESTAMP: `resolved_at`.
    - STATUS CHANGE: `Resolution#resolve_to(:failed)` → `@status = :failed` (fire-once enforced).

D9. Continuing `instance.perform`:
  - Any portion after `fail!(error)` runs normally; if perform later returns a Hash, that Hash is captured to `job.result` at D10. Errors here are safe — they propagate to `perform_job`'s rescue, get logged as post-resolution via `log_post_resolution_error` (C11's second early-return), and the lifecycle continues at D12 below.

D10. Continuing the `around_perform` middleware chain core:
  - Continuing `timed_perform(instance)`:
    - TIMESTAMP: `perform_finished_at`.
  - FLAG SET: `Job#_prevent_status_changes!` — re-engaged in the core block's ensure.
  - `capture_chain_result(target, raw_result)`:
    - `resolution.set_result(raw_result)` — set-once on the result axis. `result_set?` is false at this point because D8 touched only the error axis (`@error_set`); the result axis is untouched. If perform happens to return a Hash, that Hash is captured as `job.result` alongside the error data captured in D8. Non-Hash returns silently no-op. **This is intentional under Resolution's orthogonal model — the result axis records "what perform returned" and the error axis records "what perform signaled," and Variant D legitimately lands both (manual fail then a partial-payload hash for telemetry/audit). `after_perform` hooks can read both.**

D11. Continuing `run_hooked_perform`:
  - HOOKS: Continuing `around_perform` middleware, portions after yield (safe in this variant because the job is already failed — errors propagate to `perform_job`'s rescue, get logged as post-resolution, and the lifecycle continues at D12 below).
  - FLAG CLEARED: `Job#_allow_status_changes!`.
  - `handle_success(job, result, configuration)` exits early (no-op) because `!job.ready?`.

D12. Continuing `Worker.perform_job(job)`:
  - perform_job's ensure block:
    - FLAG CLEARED: `Job#_allow_status_changes!` (defensive).
    - HOOKS: `after_perform` via `Hooks.run(:after_perform, job, safe: true)` (safe — errors are logged and swallowed). Fires because `job.resolved?` is true (the manual setter resolved the lifecycle in D8 before the partial-payload return at D10).

D13. Continuing `Runner#execute_job(job)`:
  - HOOKS: Continuing `around_job_execution` middleware, portions after yield (safe — errors are logged and swallowed).
  - execute_job's ensure block:
    - `refresh_buffer_size!(job)` — updates `buffer_size` on `Activation` to the runner's current queue depth. No-op for unbuffered jobs (polling, `Streaming#run_inline`) and for runners without a buffer.
    - TIMESTAMP: `executed_at`.
    - HOOKS: `on_job_executed` via `Hooks.run(:on_job_executed, job, safe: true)` (safe).

Runner continues to the next job.

## Lifecycle Edge Cases

The categories below trace what happens at the boundaries of the four typical-lifecycle variants. Sub-variants that differ only by originating site cross-link to a shared trace rather than duplicating prose — same convention as Variants A–D's "errors jump to Variant C" / "errors come in at C10 from A/B" cross-links.

### E. `Busybee::Worker::Shutdown` propagation

`Busybee::Worker::Shutdown` (a `Busybee::Error` < `StandardError`) signals that the worker process is unhealthy and must terminate. It propagates past every safe layer — both `Hooks.run(safe:)` and `Chain.build_safe` rescue Shutdown specifically and re-raise it (`hooks/chain.rb:45–46`; the explicit `rescue Busybee::Worker::Shutdown; raise` in `Hooks.run`). Once Shutdown leaves `Runner#execute_job`, it bubbles to the Runner's run loop and terminates the runner thread.

**E1. Raised directly from `instance.perform`.**

**At a glance:**

```
-- instance.perform raises Shutdown --
TIMESTAMP: perform_finished_at
-- status changes prevented --
-- around_perform middleware post-yield NOT run (unsafe — Shutdown propagates) --
-- status changes allowed --
-- error captured to Job (early, via underlying_error unwrap of Shutdown.cause) --
-- autofail attempted (if fail_job_on_error and ready?) --
GRPC: job failed (engine sees Shutdown.cause)
TIMESTAMP: resolved_at
STATUS CHANGE: -> failed
HOOK: after_perform (safe, conditional on resolved?)
MIDDLEWARE: around_job_execution finish (safe — Shutdown bypasses swallow, post-yield NOT run)
TIMESTAMP: executed_at
HOOK: on_job_executed (safe)
-- Shutdown bubbles to Runner's run loop, worker terminates --
```

**Walkthrough:**

  - Continuing `timed_perform(instance)`:
    - TIMESTAMP: `perform_finished_at` (stamped in `timed_perform`'s ensure as perform exits, same as A8/B8/C8/D8).
  - FLAG SET: `Job#_prevent_status_changes!` — re-engaged in the core block's ensure.
  - MIDDLEWARE: `around_perform` finish (unsafe — Shutdown propagates through the chain; post-yield does NOT run).
  - The error is rescued by `perform_job`'s `rescue StandardError` (Shutdown < StandardError).
  - `handle_perform_exception(job, shutdown)`:
    - FLAG CLEARED: `Job#_allow_status_changes!`.
    - EARLY ERROR CAPTURE: `resolution.set_error(underlying_error(shutdown))` — captures `shutdown.cause` (not the wrapper). See E5.
    - `handle_failure` → `attempt_auto_fail` → `job.fail!(underlying_error(shutdown), backoff: configuration.backoff)` (when `fail_job_on_error` and `job.ready?`):
      - GRPC CALL: `client.fail_job(key, message, retries: nil, backoff: backoff)`. **Workflow engine now sees the job as failed with the Shutdown's underlying cause.**
      - TIMESTAMP: `resolved_at`.
      - STATUS CHANGE: `Resolution#resolve_to(:failed)` → `@status = :failed`.
    - Explicit `raise if exception.is_a?(Shutdown)` re-raises past `perform_job`.
  - `perform_job`'s ensure block:
    - FLAG CLEARED: `Job#_allow_status_changes!` (defensive).
    - HOOK: `after_perform` via `Hooks.run(:after_perform, job, safe: true)` (safe — fires only when `job.resolved?`, i.e. autofail succeeded). The Job carries the early-captured error either way.
  - MIDDLEWARE: `around_job_execution` finish (safe — `Chain.build_safe` re-raises Shutdown at `hooks/chain.rb:45–46`, so middleware post-yield does NOT run).
  - `execute_job`'s ensure block:
    - `refresh_buffer_size!(job)`.
    - TIMESTAMP: `executed_at`.
    - HOOK: `on_job_executed` via `Hooks.run(:on_job_executed, job, safe: true)` (safe).
  - Shutdown bubbles out of `Runner#execute_job` to the Runner's run loop, which begins terminating.

**E2. Raised from an unsafe hook (`before_perform`, `around_perform` pre-yield, `around_perform` post-yield).**

The three origin sites converge on E1's "rescued by `perform_job`'s `rescue StandardError`" — from there, **the trace continues as E1**. The pre-rescue prefix differs per site:

  - From `before_perform` (flag set in Common 6): `Hooks.run(:before_perform, ..., safe: false)` re-raises via its explicit Shutdown clause. The around chain never starts; `perform_started_at` and `perform_finished_at` are NOT stamped.
  - From `around_perform` pre-yield (flag set in Common 6): `Chain.build_propagating` has no rescues at the middleware layer — Shutdown propagates straight out. The around chain's core block was never entered, so the core ensure (which re-sets the flag) does NOT fire. `perform_started_at` and `perform_finished_at` are NOT stamped.
  - From `around_perform` post-yield (flag re-set by the core ensure): `perform_finished_at` IS stamped (perform completed before the offending hook). The result axis may carry whatever `perform` returned — `capture_chain_result` ran in the core block before the ensure unwound into the offending middleware.

**E3. Triggered by `shutdown_on` match — a non-Shutdown `StandardError` matches the worker's `shutdown_on` configuration.**

Wrap site depends on origin:

  - **From perform or any unsafe hook surface** that propagates to `perform_job`'s rescue: `handle_perform_exception` runs as in C10–C13. After `handle_failure` runs autofail (the original error is not yet Shutdown — regular StandardError path), `shutdown_error?(exception, configuration)` matches, and `raise Shutdown.new(worker: self)` fires (Ruby sets `cause` to the original). From here, **the trace continues as E1** from "MIDDLEWARE: `around_job_execution` finish".
  - **From a safe hook** (`on_job_activated`, `after_perform`, `on_job_executed`, `around_job_execution`): `Hooks.run`'s rescue checks `shutdown_error?` inline and raises `Shutdown.new(worker: nil)` directly. Hook iteration short-circuits. From here, **cross-link to E4** — propagation depends on hook site.

Important asymmetry: in the perform-side path, **autofail runs before the Shutdown wrap**, so the engine sees the underlying error via `fail_job` in addition to learning the worker is shutting down via the abandoned activation. In the safe-hook path, autofail does not run (it's only reachable from `perform_job`'s rescue).

**E4. Raised from a safe hook (`on_job_activated`, `after_perform`, `on_job_executed`, `around_job_execution`).**

`Hooks.run(safe: true)` and `Chain.build_safe` both have explicit `rescue Busybee::Worker::Shutdown; raise` clauses — Shutdown bypasses the swallow-errors logic at every layer. Surface point depends on origin site:

  - `on_job_activated`: raised inside `Runner#activate_job`. Propagates past the activate step, past whichever receive path activated this job (`Polling`, `Streaming`, `Hybrid`), into the Runner's run loop. The receive path's `executed_at` and `on_job_executed` for this job do NOT fire.
  - `after_perform`: raised inside `perform_job`'s ensure block. The `Hooks.run(:after_perform, safe: true)` rescue re-raises rather than logging. Shutdown emerges from `perform_job`. **The trace continues as E1** from "MIDDLEWARE: `around_job_execution` finish".
  - `on_job_executed`: raised inside `Runner#execute_job`'s ensure, after the runner-level safe around chain already completed. `executed_at` and `refresh_buffer_size!` both happened before this point. Shutdown propagates past the receive path into the Runner's run loop.
  - `around_job_execution`: raised inside the runner-level safe around chain. `Chain.build_safe` re-raises Shutdown. Same downstream as E1's tail (Shutdown exits `Runner#execute_job` after the ensure runs).

**E5 (callout on C12).** `underlying_error`'s Shutdown unwrap.

  When `attempt_auto_fail` (or `handle_perform_exception`'s early-capture step) is called with a Shutdown wrapping a cause, `underlying_error(shutdown)` returns `shutdown.cause` (or the Shutdown itself if no cause is set). This is what `fail_job` sends to the engine and what `set_error` captures on Resolution. The Shutdown wrapper is the framework's internal signal for "tear down the worker"; the engine and Resolution see the underlying cause. (See E3 for the inverse direction: the wrap site that creates the Shutdown in the first place.)

### F. `Busybee::StatusChangeOutsidePerform` flag-catch

`Busybee::StatusChangeOutsidePerform` (a `Busybee::Error` < `StandardError`) is raised by `Job#check_status_change_allowed!` when `complete!` / `fail!` / `throw_bpmn_error!` is called while `Job#_status_changes_prevented` is set — i.e., from a hook surface that shouldn't be resolving the job. Like Shutdown, it's caught by `perform_job`'s `rescue StandardError` and explicitly re-raised past `handle_perform_exception` (C13's `raise if exception.is_a?(Busybee::StatusChangeOutsidePerform)`). Unlike Shutdown, the runner-level `Chain.build_safe` does NOT specifically re-raise it — `StatusChangeOutsidePerform` falls into the generic `rescue StandardError` branch and is logged-and-swallowed there. The runner continues to the next job; the worker process is not terminated.

The flag's state across the lifecycle:

- Common 1–5: cleared (initial).
- Common 6 (`run_hooked_perform` entry): SET, just before `before_perform`.
- Common 7 (inside `around_perform` middleware chain core): CLEARED, immediately before `timed_perform`.
- A8 / B11 / C8 / D10 (core block's ensure): RE-SET, before middleware unwinds.
- After the around chain in `run_hooked_perform`: CLEARED, before `handle_success`.
- `perform_job`'s ensure: CLEARED defensively (also covers non-StandardError escapes — see Category H).

**F1. Raised from a `before_perform` hook.**

**At a glance:**

```
-- before_perform raises StatusChangeOutsidePerform (flag is set) --
-- around chain never starts --
-- status changes allowed --
-- error captured to Job (early in handle_perform_exception) --
-- autofail attempted (if fail_job_on_error and ready?) --
GRPC: job failed (engine sees StatusChangeOutsidePerform as failure reason)
TIMESTAMP: resolved_at
STATUS CHANGE: -> failed
HOOK: after_perform (safe, conditional on resolved?)
MIDDLEWARE: around_job_execution finish (safe — StatusChangeOutsidePerform logged and swallowed)
TIMESTAMP: executed_at
HOOK: on_job_executed (safe)
-- Runner continues to the next job --
```

**Walkthrough:**

  - The flag is set in Common 6 just before `before_perform` runs. A hook calling `complete!`/`fail!`/`throw_bpmn_error!` triggers `check_status_change_allowed!`, which raises `StatusChangeOutsidePerform`.
  - HOOKS: `before_perform` (unsafe — `Hooks.run(safe: false)`'s rescue checks `shutdown_error?` first, no match, then re-raises since `safe: false`).
  - The error escapes `run_hooked_perform` past the around chain (which never started).
  - The error is rescued by `perform_job`'s `rescue StandardError`.
  - `handle_perform_exception(job, scop)`:
    - FLAG CLEARED: `Job#_allow_status_changes!`.
    - EARLY ERROR CAPTURE: `resolution.set_error(scop)` (no Shutdown unwrap; SCOP is not Shutdown-class).
    - `handle_failure` → `attempt_auto_fail` → `job.fail!(scop, backoff: configuration.backoff)` (when `fail_job_on_error` and `job.ready?` — true here, since no perform-side resolution ran):
      - GRPC CALL: `client.fail_job(key, "[Busybee::StatusChangeOutsidePerform] <message>", retries: nil, backoff: backoff)`. **Workflow engine now sees the misuse as the failure reason.**
      - TIMESTAMP: `resolved_at`.
      - STATUS CHANGE: `Resolution#resolve_to(:failed)` → `@status = :failed`.
    - Explicit `raise if exception.is_a?(Busybee::StatusChangeOutsidePerform)` re-raises past `perform_job`.
  - `perform_job`'s ensure block:
    - FLAG CLEARED: `Job#_allow_status_changes!` (defensive).
    - HOOK: `after_perform` via `Hooks.run(:after_perform, job, safe: true)` (safe — fires since `job.resolved?` is true from autofail).
  - MIDDLEWARE: `around_job_execution` finish (safe — `Chain.build_safe`'s `rescue StandardError` matches, `log_swallowed_error` logs the misuse, `next_link.call unless called` is a no-op since `perform_job` already ran).
  - `execute_job`'s ensure block:
    - `refresh_buffer_size!(job)`.
    - TIMESTAMP: `executed_at`.
    - HOOK: `on_job_executed` via `Hooks.run(:on_job_executed, job, safe: true)` (safe).
  - Runner continues to the next job.

**F2. Raised from `around_perform` middleware pre-yield.**

Same flag state as F1 (set in Common 6). Pre-yield middleware runs after `before_perform` but before the core block's `_allow_status_changes!`. `Chain.build_propagating` has no rescues at the middleware layer — `StatusChangeOutsidePerform` propagates straight out. The around chain raises before entering its core block, so the core ensure (which re-sets the flag) does NOT fire — the block was never entered. From here, **the trace continues as F1** from "the error escapes `run_hooked_perform`".

Distinguishing detail: `perform_started_at` and `perform_finished_at` are NOT stamped (perform never ran). The result and error axes on Resolution are untouched until the early-capture in `handle_perform_exception`.

**F3. Raised from `around_perform` middleware post-yield.**

The flag was cleared in Common 7 to let `perform` run, then RE-SET in the core block's ensure (A8/B11/C8/D10) just before middleware unwinds. Post-yield middleware code sees the flag set; calling `complete!`/etc. raises. From here, **the trace continues as F1** from "the error escapes `run_hooked_perform`".

Distinguishing details: `perform_finished_at` IS stamped (perform completed before the offending hook fired). The result axis may carry whatever `perform` returned (captured by `capture_chain_result` in the core block).

**F4. From `after_perform` (sanity check, expected not to fire).**

By the time `after_perform` runs in `perform_job`'s ensure, the flag has been cleared defensively. `check_status_change_allowed!` passes the flag check. Under the conditional-on-resolved guard on `after_perform`, the hook only fires when `job.resolved?` is already true; a hook calling `complete!`/`fail!`/`throw_bpmn_error!` from here hits the `unless ready?` guard inside those methods and raises `Busybee::JobAlreadyHandled`, not `StatusChangeOutsidePerform`. Documented as a non-trace: the flag-catch is structurally prevented at this site by the defensive clear; the already-resolved guard is what trips a hook misuse here.

### G. GRPC call failures

Each resolution lifecycle method makes exactly one GRPC call: `complete!` → `client.complete_job`, `fail!` → `client.fail_job`, `throw_bpmn_error!` → `client.throw_bpmn_error`. All three go through the Client's `with_retry` wrapper (`client/error_handling.rb`), which optionally retries once at the client layer (`Busybee.grpc_retry_enabled`, off by default) and wraps `::GRPC::BadStatus` in `Busybee::GRPC::Error` (a `Busybee::Error` < `StandardError`; the BadStatus is chained as `cause`). A failed resolution call therefore surfaces to job-lifecycle code as an ordinary StandardError. Activation-side GRPC failures (the polling/streaming receive calls) happen before a Job exists and are runner-level concerns outside these traces; `update_retries`/`update_timeout` failures raise the same `Busybee::GRPC::Error` but touch no Resolution state — inside perform they behave like any other perform-raised StandardError (Variant C).

**Worker-side state vs. engine-side state.** `result` and `error` are worker-side records of what came out of executing the job; `status` is the engine's ledger *as reflected on this worker* — it advances only after the relevant GRPC call succeeds. The worker never observes engine state directly, so the two can diverge: `:failed` on the worker can pair with an incident on the engine, and `:ready` on the worker can pair with the engine still seeing the job as ACTIVATED (the engine-side name — visible in Operate and the Zeebe API — for what Busybee calls `:ready`). This split is the source of every G surprise.

Three design invariants govern every trace below:

1. **Outcome data is captured before the GRPC.** All three lifecycle methods call `resolution.set_result`/`set_error` *before* their GRPC call, so the Job carries the intended outcome even when the engine never learns of it.
2. **Framework-issued calls swallow; user-initiated calls propagate.** The framework's own resolution calls — auto-complete in `handle_success`, autofail in `attempt_auto_fail` — rescue GRPC failures internally, capture the error on Resolution for telemetry, log a warning, and continue (G1, G3). (Capture nuance: G1's rescue calls `set_error(e)` on the GRPC error since perform succeeded and there's no prior error to preserve; G3's rescue does NOT capture, because the original perform error was already early-captured at C10 and the error axis is set-once.) User-initiated lifecycle calls inside perform have no such rescue; the failure raises out of the perform call site and lands at C10 like any perform-raised error (G2, G4, G5). One consequence parallels E3's autofail-before-wrap asymmetry: only the propagating sub-variants reach C13's `shutdown_error?` check, so configuring `Busybee::GRPC::Error` in `shutdown_on` converts G2/G4/G5 into E3 — while G1/G3's swallowed failures never reach the wrap site.
3. **G1 and G3 involve exactly one GRPC call.** G1 swallows the auto-complete failure entirely (no autofail attempted; `handle_success` rescues internally, before any rescue path that would route to `attempt_auto_fail`). G3 *is* the autofail's `fail_job`, and its failure is caught by `attempt_auto_fail`'s internal rescue. G2/G4/G5 involve a primary call plus an autofail attempt, so they fork along the two failure modes below.

**Two failure modes shape G2, G4, and G5.** The primary call fails; whether the autofail's `fail_job` *also* fails depends on what kind of outage we're seeing.

- **Correlated outage** (the realistic same-network failure mode — network down, broker unreachable, GRPC channel broken): the autofail's `fail_job` also fails. `attempt_auto_fail` swallows it; the job stays `:ready` worker-side, the engine still holds the activation, the activation times out, and the engine re-yields the job with its retries count fully intact (the engine never received any of the failed calls). `after_perform` stays silent (conditional on `resolved?`); `on_job_executed` is the per-attempt signal.
- **Isolated transient** (less common — a single call gets a `GRPC::Unavailable` or `GRPC::DeadlineExceeded` while the connection otherwise works): the autofail's `fail_job` succeeds. Worker-side, `:failed` is recorded. Engine-side under today's code, see the known-bug callout immediately below.

**Known bug, out of scope for this commit, will be fixed before v1.0.** `Job#fail!`'s default `retries:` argument is `nil`, which `Client#fail_job` passes through; the proto3 `int32` field then transmits as `0` on the wire. Zeebe interprets `FailJobRequest.retries = 0` as "remaining retries exhausted" and raises an incident immediately. Every framework-issued autofail today therefore takes the incident path, not the retry path, despite the BPMN's configured `retries` setting — every isolated-transient G2/G4/G5 ends with the engine in incident state until an operator intervenes. The intended fix (decrement the activation count when the caller doesn't supply `retries:`, honoring an `update_retries` override exactly when set) is tracked in the gem's task list. **An explicit `update_retries(N)` call before `fail!` does NOT protect against this bug** — engine state is last-write-wins, and the bare-fail wire value of `0` overwrites whatever the override set. Verified empirically against Camunda 8.8 during M6e.

Where each sub-variant lands (today's behavior, with the known bug in effect):

| | Failing call | Handling | Worker-side state after | Engine's next move (today) |
|---|---|---|---|---|
| G1 | `complete_job` (auto-complete, A) | logged + swallowed in `handle_success` | `:ready`; result set, error set (for telemetry) | activation times out → re-yield with retries intact |
| G2 | `complete_job` (manual `complete!`, B) | propagates to C10; autofail attempted | isolated transient: `:failed` with both axes set; correlated outage: `:ready` with both axes set | isolated transient: **incident raised** (bug: autofail sent `retries=0`); correlated outage: re-yield with retries intact |
| G3 | `fail_job` (autofail, C) | logged + swallowed in `attempt_auto_fail` | `:ready`; error set (original perform error) | activation times out → re-yield with retries intact |
| G4 | `fail_job` (manual `fail!`, D) | propagates to C10; autofail retries the fail | same as G2 | same as G2 |
| G5 | `throw_bpmn_error` (manual, D) | propagates to C10; autofail attempts a *fail* | `:failed` (isolated transient) — **never `:error`** — or `:ready` (correlated outage); BPMN error data on error axis | same as G2 (engine never sees the BPMN error code; the error boundary is never reached) |

**An irony for at-scale operators to internalize.** Under today's retries-default bug, the *worse* engine-side outcome (incident, operator attention) happens in the *less* catastrophic failure mode (isolated transient), while the *more* catastrophic failure mode (correlated outage — network down across many jobs) produces the *more* recoverable engine-side outcome (re-yield with retries intact). Once the bug is fixed, isolated transients will drain a single retry and re-yield normally; the irony evaporates.

**G1. `complete_job` fails during auto-complete (Variant A).**

**At a glance:**

```
-- instance.perform returns --
TIMESTAMP: perform_finished_at
-- status changes prevented --
-- result captured to Job --
MIDDLEWARE: around_perform finish (unsafe)
-- status changes allowed --
VALIDATION: required outputs (unsafe)
VALIDATION: undeclared outputs (unsafe)
GRPC: complete_job FAILS (engine still sees the job as activated)
-- error captured to Job (in handle_success rescue) --
-- failure logged and swallowed in handle_success --
HOOK: after_perform NOT fired (job not resolved)
MIDDLEWARE: around_job_execution finish (safe)
TIMESTAMP: executed_at
HOOK: on_job_executed (safe — observes :ready + both axes set)
-- activation times out; engine re-yields the job --
```

**Walkthrough:**

Follows Variant A unchanged through A10. G1 deviates at A11, inside `handle_success`'s begin block:

  - `job.complete!(result)`:
    - `resolution.set_result(vars)` — silent no-op (set-once; already set in A8). **The result axis is set even though completion is about to fail.**
    - GRPC CALL: `client.complete_job(key, vars: ...)` raises `Busybee::GRPC::Error`. **Workflow engine never hears about the completion; it still sees the job as activated.**
    - `resolve!(:complete)` does NOT run (`.tap`'s block is never reached). No `resolved_at` timestamp, no status change — the job remains `:ready`.
  - The error unwinds out of `job.complete!` into `handle_success`'s `rescue StandardError`:
    - ERROR CAPTURE: `resolution.set_error(e)` — records the rescued `Busybee::GRPC::Error` on the error axis before swallowing. Symmetry with G2's early capture in `handle_perform_exception`: both telemetry surfaces (`after_perform`, `on_job_executed`) see *why* the completion failed.
    - Logged: `"Failed to complete job #{job.key}: ... Job will timeout and retry."` — and swallowed. `run_hooked_perform` returns normally; `perform_job`'s `rescue StandardError` is never involved.
  - `perform_job`'s ensure block:
    - FLAG CLEARED: `Job#_allow_status_changes!` (defensive).
    - HOOK: `after_perform` NOT fired — `job.resolved?` is false. The job is `:ready` with **both** axes set: the canonical "result set does not imply success, and error set does not imply failure on the engine side" case under Resolution's orthogonal model.
  - MIDDLEWARE: `around_job_execution` finish (safe) — runs normally; nothing is propagating.
  - `execute_job`'s ensure block:
    - `refresh_buffer_size!(job)`.
    - TIMESTAMP: `executed_at`.
    - HOOK: `on_job_executed` via `Hooks.run(:on_job_executed, job, safe: true)` (safe) — the per-attempt signal; observes `:ready` with the result axis set.
  - Runner continues to the next job. The activation times out engine-side and the job is re-yielded.

**G2. `complete_job` fails during manual `complete!` (Variant B).**

**At a glance:**

```
-- instance.perform calls complete!(result) --
VALIDATION: required outputs (unsafe)
VALIDATION: undeclared outputs (unsafe)
-- result captured to Job --
GRPC: complete_job FAILS (engine still sees the job as activated)
-- GRPC::Error raises out of complete!, aborting the rest of instance.perform --
TIMESTAMP: perform_finished_at
-- status changes prevented --
-- around_perform middleware post-yield NOT run --
-- status changes allowed --
-- error captured to Job (early in handle_perform_exception) --
-- autofail attempted (if fail_job_on_error and ready?) --
GRPC: autofail fail_job — engine raises INCIDENT (bug: retries: nil → wire 0)
TIMESTAMP: resolved_at
STATUS CHANGE: -> failed (worker-side; engine has incident)
HOOK: after_perform (safe, conditional on resolved?)
MIDDLEWARE: around_job_execution finish (safe)
TIMESTAMP: executed_at
HOOK: on_job_executed (safe)
```

The at-a-glance above traces the **isolated transient** branch (autofail's `fail_job` succeeds); the **correlated outage** branch swallows at C12 and ends `:ready` → activation timeout → re-yield. See the prose below.

**Walkthrough:**

Begins as B8–B9 and ends as C10–C15; what's distinctive is the state carried into C10.

  - B8: `Worker#complete!` output validations pass.
  - B9, inside `job.complete!`:
    - `resolution.set_result(vars)` — **result axis set before the GRPC.**
    - GRPC CALL: `client.complete_job(key, vars: ...)` raises `Busybee::GRPC::Error`. Engine still sees the job as activated; `resolve!(:complete)` never runs; the job remains `:ready`.
  - The GRPC::Error raises out of `complete!` at its perform call site, aborting the remainder of `instance.perform`. From here **the trace continues as Variant C from C8** ("instance.perform raises StandardError" — here, the GRPC::Error): `perform_finished_at` stamps, the flag re-sets, `around_perform` post-yield middleware does NOT run, and the error lands at C10.
  - Distinctive state at C10 (vs. plain Variant C):
    - EARLY ERROR CAPTURE: `resolution.set_error(grpc_error)` — captures the *GRPC error* (`underlying_error` passes non-Shutdown errors through). **Both axes are now set: the result perform intended to deliver, and the error that blocked delivery.** `after_perform` hooks can read both.
    - `handle_failure`: the job is still `ready?` (the manual complete never resolved), so `attempt_auto_fail` runs — `job.fail!(grpc_error, backoff: configuration.backoff)`:
      - Inside `fail!`: `resolution.set_error(...)` — silent no-op (set-once on the error axis).
      - GRPC CALL: `client.fail_job(key, "[Busybee::GRPC::Error] ...", retries: nil, backoff: backoff)`.
      - **Isolated transient** (this `fail_job` succeeds, today's bug in effect): the engine receives `FailJobRequest.retries = 0` (per the known-bug callout above) and **raises an incident immediately**. The engine never learns the result hash, only that retries are exhausted; the worker-side Job carries both result and error. `resolved_at` stamps; STATUS CHANGE: → `:failed` (worker-side); `after_perform` fires at C14. Operator intervention is required engine-side to resume the process instance.
      - **Correlated outage** (this `fail_job` also fails — the realistic same-network case): `attempt_auto_fail` logs and swallows per C12; the job stays `:ready` worker-side; `after_perform` stays silent; the activation times out and the engine re-yields the job with retries fully intact (none of the failed calls reached engine state).
    - C13: `shutdown_error?(grpc_error, configuration)` — if `Busybee::GRPC::Error` (or an ancestor) is configured in `shutdown_on`, the wrap fires and **the trace continues as E3** (perform-side path). Not matched by default.
  - The tail is C14–C15 unchanged.

**G3. `fail_job` fails during autofail (Variant C).**

No new trace shape — C12's closing bullet already covers the mechanics; this names the resulting state. Variant C runs unchanged through C12, where `attempt_auto_fail`'s internal rescue catches the `Busybee::GRPC::Error`, logs `"Failed to fail job #{job.key}: ... Job will timeout and retry."`, and swallows it. From there **the trace continues as C13** with the *original perform error* — the GRPC failure never escapes `attempt_auto_fail`, so it is invisible to C13's Shutdown/`shutdown_on` checks (the intro's swallow-vs-propagate asymmetry).

Resulting state: error axis set with the original perform error (C10's early capture — not the GRPC error); result axis unset; status `:ready`. `after_perform` silent at C14; `on_job_executed` fires at C15 as the per-attempt signal. The activation times out and the job is re-yielded — autofail's intended `backoff` never applied, and the engine's retry count is untouched.

**G4. `fail_job` fails during manual `fail!` (Variant D).**

Same shape as G2 with fail-side specifics. Begins at D8: `resolution.set_error(error_data)` — **error axis set with the user's intended error data before the GRPC** — then `client.fail_job` raises `Busybee::GRPC::Error`; `resolve!(:failed)` never runs; the job remains `:ready`. The GRPC::Error raises out of `fail!` at its perform call site, aborting the remainder of `instance.perform`; **the trace continues as Variant C from C8** and lands at C10.

Distinctive state at C10 (contrast G2):

  - EARLY ERROR CAPTURE: `resolution.set_error(grpc_error)` — **silent no-op.** The error axis already carries the user's intended error data from D8 (set-once). The Job permanently records what the worker meant to signal, not the transport failure that blocked it.
  - `attempt_auto_fail` retries the fail with the *GRPC error*: `job.fail!(grpc_error, backoff: configuration.backoff)` — its internal `set_error` no-ops again.
  - **Isolated transient** (this `fail_job` succeeds, today's bug in effect): the engine receives `FailJobRequest.retries = 0` and **raises an incident immediately**. The engine's failure message is the GRPC error's (`"[Busybee::GRPC::Error] ..."`) — the engine recording the transport failure is intentional signal for external monitoring, not noise — while the Job's error axis carries the user's original `fail!` data. The user's original `retries:`/`backoff:` arguments are silently dropped on autofail recovery (they live nowhere on the Job; autofail substitutes `configuration.backoff` and the buggy `nil` retries default). Operator intervention required.
  - **Correlated outage** (this `fail_job` also fails): same tail as G3 — `:ready`, `after_perform` silent, activation timeout, engine re-yields with retries intact.
  - Result axis: unset. Perform aborted at the `fail!` call site, so — unlike a successful Variant D — there is no D10 partial-payload capture (`capture_chain_result` is bypassed by the propagating error).
  - C13 `shutdown_on` interaction: same as G2.

**G5. `throw_bpmn_error` fails during manual `throw_bpmn_error!` (Variant D).**

Same shape as G4; the deltas:

  - The pre-GRPC capture is `resolution.set_error(bpmn_error_data(...))` — the error axis carries `error_code` and `error_message` (plus `error` when an Exception was passed) before the GRPC.
  - The recovery path is autofail, not a BPMN-error retry: the framework only knows how to auto-recover *failures*, not BPMN errors. The job resolves `:failed` worker-side — **never `:error`** — and the engine never sees the BPMN error code at all.
  - **Isolated transient** (autofail's `fail_job` succeeds, today's bug in effect): engine raises an incident (a failed job with `retries=0`); the BPMN error never reaches an error boundary in the process definition. The intended-but-undelivered BPMN routing is visible worker-side as the error axis's `error_code` alongside status `:failed`.
  - **Correlated outage** (autofail's `fail_job` also fails): `:ready` worker-side with `error_code` set on the error axis; engine re-yields the job for another attempt at perform, with retries intact. Hook surfaces can observe the undelivered BPMN intent on the unresolved job.

### H. Non-`StandardError` serious exceptions

"Safe" in this gem means **rescues `StandardError`**. It does NOT mean "rescues anything." Exceptions that descend from `Exception` without going through `StandardError` — `ScriptError` descendants (`SyntaxError`, `LoadError`, `NotImplementedError`), `NoMemoryError`, `SystemStackError`, plus the signal-control-flow classes `SignalException` (with descendant `Interrupt`) and `SystemExit` — bypass every rescue in the lifecycle, including the ones labeled safe. There are no explicit re-raise clauses for them anywhere in the gem because none are needed: a non-`StandardError` never matches the `rescue StandardError` in the first place, so it propagates implicitly.

**Two flavors worth separating, plus a third category that isn't really a "perform error" at all.** Deterministic developer errors (`SyntaxError`, `LoadError`, `NotImplementedError` — same input → same error on every attempt) are the *poison-pill* cases under today's behavior: a job that triggers them will trigger them again on every re-yield, retries never drain (activation timeout doesn't decrement engine-side retries; see Category G), and the job effectively eats activations forever. Situational unrecoverable errors (`NoMemoryError`, `SystemStackError`) are process-level conditions where even running autofail's `fail_job` would likely fail (the message allocation alone could OOM; the stack growth alone could overflow). The gem currently treats both alike — they all propagate out — but the operationally-correct behavior differs: deterministic errors deserve autofail-and-incident, the same as a deterministic `StandardError`, so the operator gets a clear signal in Operate; situational errors should propagate to the supervisor for a restart. Widening the rescue scope to capture the deterministic group (`ScriptError` family and similar) is tracked as future work; for now, both groups follow the same path below. The third category — signal-control-flow classes (`SignalException`, `Interrupt`, `SystemExit`) — isn't a perform error at all: the gem's CLI traps `INT`/`QUIT`/`TERM` at `cli.rb:46-50` and routes through `runner.stop!`, raising `Busybee::Worker::Shutdown` for in-flight jobs (Category E). A raw signal-class exception reaching the perform path is essentially unreachable under `bin/busybee` — it would require user code raising `Interrupt` directly, or someone embedding the runner without equivalent signal traps. For the traces below, treat `SyntaxError` / `LoadError` / `NoMemoryError` as the representative shapes.

Two consequences shape every trace below:

1. **Worker.perform_job's `rescue StandardError` does NOT catch.** `handle_perform_exception` does not run; no early error capture, no autofail, no `shutdown_error?` check (and therefore no `Shutdown` wrap — Category E's perform-side path is unreachable from H). The error simply propagates out.
2. **Every `ensure` block still fires.** `timed_perform`'s ensure stamps `perform_finished_at`, the core block's ensure re-sets the status-change flag, `perform_job`'s ensure clears it defensively and checks `Hooks.run(:after_perform, job, safe: true) if job.resolved?` (false on H paths, so no fire), and `execute_job`'s ensure refreshes the buffer, stamps `executed_at`, and fires `on_job_executed`. Observability of the abandoned activation survives.

Once a non-`StandardError` exits `Runner#execute_job`, it propagates past the runner's run-loop `rescue Busybee::Worker::Shutdown` (which matches Shutdown only) and into whatever process supervises the runner. That's outside per-job-lifecycle scope; H traces end at the `Runner#execute_job` exit.

**H1. Raised directly from `instance.perform`.**

**At a glance:**

```
-- instance.perform raises SyntaxError / LoadError / NoMemoryError / etc. --
TIMESTAMP: perform_finished_at
-- status changes prevented --
-- around_perform middleware post-yield NOT run (build_propagating has no rescues) --
-- error NOT captured to Job (perform_job's rescue StandardError does NOT match) --
-- autofail NOT attempted (handle_perform_exception did not run) --
-- status changes allowed (defensive clear in perform_job ensure) --
HOOK: after_perform NOT fired (job not resolved)
-- around_job_execution post-yield NOT run (build_safe's rescue is StandardError-only) --
TIMESTAMP: executed_at
HOOK: on_job_executed (safe — its own StandardError errors swallowed; the original non-StandardError keeps propagating once the hook returns)
-- non-StandardError exits Runner#execute_job; bubbles past the runner loop's Shutdown-scoped rescue (no match), into the supervising process --
-- engine still sees the job as ACTIVATED; activation times out; re-yield as a fresh Job --
```

**Walkthrough:**

  - Continuing `timed_perform(instance)`:
    - TIMESTAMP: `perform_finished_at` (stamped in `timed_perform`'s ensure as perform exits, same as A8/B8/C8/D8 — every variant stamps this).
  - FLAG SET: `Job#_prevent_status_changes!` — re-engaged in the core block's ensure.
  - MIDDLEWARE: `around_perform` finish — does NOT run. `Chain.build_propagating` (used for `:around_perform`) has no rescues at the middleware layer; non-`StandardError` propagates through the chain and after-yield code is skipped.
  - The error reaches `perform_job`'s `rescue StandardError` and **does NOT match**. EARLY ERROR CAPTURE does not run; `handle_failure` does not run; `attempt_auto_fail` does not run; the `shutdown_error?` check at C13 is unreachable. The Job's error axis stays unset; the result axis stays unset (perform raised before capture_chain_result ran).
  - `perform_job`'s ensure block:
    - FLAG CLEARED: `Job#_allow_status_changes!` (defensive — exactly the case this clear was added for).
    - HOOK: `after_perform` NOT fired — `job.resolved?` is false.
  - MIDDLEWARE: `around_job_execution` finish (safe) — does NOT run. `Chain.build_safe`'s `rescue StandardError` does NOT match; non-`StandardError` propagates through.
  - `execute_job`'s ensure block (always runs):
    - `refresh_buffer_size!(job)`.
    - TIMESTAMP: `executed_at`.
    - HOOK: `on_job_executed` via `Hooks.run(:on_job_executed, job, safe: true)` (safe). If the hook itself raises a `StandardError`, that's swallowed by `Hooks.run`'s safe-mode rescue; the original non-`StandardError` from perform keeps propagating once the hook returns.
  - The non-`StandardError` exits `Runner#execute_job` and propagates past the runner's run-loop `rescue Busybee::Worker::Shutdown` — which matches Shutdown only, not arbitrary `Exception` descendants. The supervising process (typically `bin/busybee` or whatever embeds the runner) is the next catch site.
  - Engine-side, the activation lock was never released; the job remains ACTIVATED until the activation times out, then is re-yielded as a fresh Job. Retries count is intact (no `fail_job` call landed). If the supervising process restarts the runner cleanly, the next attempt at this same job picks up from the engine's untouched count.

**H2. Raised from an unsafe hook (`before_perform`, `around_perform` pre-yield, `around_perform` post-yield).**

The three origin sites converge on H1's "reaches `perform_job`'s `rescue StandardError` and does NOT match" — from there, **the trace continues as H1**. The pre-rescue prefix differs per site:

  - From `before_perform` (flag set in Common 6): `Hooks.run(:before_perform, ..., safe: false)`'s `rescue StandardError` does NOT match; non-`StandardError` propagates straight out. The around chain never starts; `perform_started_at` and `perform_finished_at` are NOT stamped.
  - From `around_perform` pre-yield (flag set in Common 6): `Chain.build_propagating` has no rescues at the middleware layer — non-`StandardError` propagates straight out. The around chain's core block was never entered, so the core ensure (which re-sets the flag) does NOT fire. `perform_started_at` and `perform_finished_at` are NOT stamped.
  - From `around_perform` post-yield (flag re-set by the core ensure): `perform_finished_at` IS stamped (perform completed before the offending hook). The result axis may carry whatever `perform` returned — `capture_chain_result` ran in the core block before the ensure unwound into the offending middleware.

Identical site list and rationale as E2; the divergence is at the catch sites further down — Shutdown gets explicitly re-raised at safe layers (Category E), while non-`StandardError` bypasses them implicitly.

**H3. Raised from a safe hook (`on_job_activated`, `after_perform`, `on_job_executed`, `around_job_execution`).**

The "safe" label is misleading for non-`StandardError`: `Hooks.run(safe: true)` and `Chain.build_safe` both rescue `StandardError` only. Non-`StandardError` propagates through every safe layer. Surface point depends on origin site:

  - `on_job_activated`: raised inside `Runner#activate_job`. Propagates past the activate step, past whichever receive path activated this job (`Polling`, `Streaming`, `Hybrid`), into the supervising process. The receive path's `executed_at` and `on_job_executed` for this job do NOT fire (`execute_job` was never reached).
  - `after_perform`: raised inside `perform_job`'s ensure block during `Hooks.run(:after_perform, job, safe: true)`. The ensure already ran `Job#_allow_status_changes!` before this hook fired. Non-`StandardError` emerges from `perform_job`; **the trace continues as H1** from "MIDDLEWARE: `around_job_execution` finish".
  - `on_job_executed`: raised inside `Runner#execute_job`'s ensure, after `refresh_buffer_size!` and `executed_at` already ran. Non-`StandardError` exits `Runner#execute_job` directly and propagates as in H1's tail.
  - `around_job_execution`: raised inside the runner-level safe around chain. `Chain.build_safe`'s `StandardError`-only rescue doesn't catch. Same downstream as H1's tail.

**H4. `shutdown_on` with a non-`StandardError` class is rejected at configure-time (sanity check, non-trace).**

`Busybee.shutdown_on_errors` and the per-worker `shutdown_on` DSL both feed `shutdown_error?(exception, config)` at C13 in `handle_perform_exception`. C13 is reachable only from `perform_job`'s `rescue StandardError`, which non-`StandardError` does not match — so a non-`StandardError` registered in `shutdown_on` would never reach the check at runtime. To prevent this silent-no-op footgun, both setters validate at configure-time: `Busybee.shutdown_on_errors = [Interrupt]` raises `ArgumentError`, and `shutdown_on Interrupt` inside a worker class body raises `InvalidWorkerDefinition`. The configuration knob is `StandardError`-bound by construction. Documented as a non-trace because there's no lifecycle path to draw — the invalid configuration never makes it past assignment.

### Cross-category interactions

A closing sweep of interactions across E/F/G/H that don't fit neatly into any one category. Most are structural observations or sub-findings; none warrant their own trace, but each is worth naming so a reader doing a cross-cutting investigation has them in one place.

**Engine-doesn't-know paths unify behind activation timeout.** Several lifecycle-edge paths share the property that the engine never receives a resolution signal — the safe-hook origins of E (E4), the correlated-outage variants of G2/G4/G5 (intro to G), every H path (H1/H2/H3). In all of them, worker-side state may advance to something settled (`:failed`, `:resolved?` true) or stay `:ready`, but engine-side state stays ACTIVATED until the activation timeout fires. The unifying recovery mechanism is the engine-side timeout, which re-yields the job as a fresh Job with retries intact (no `fail_job` ever decremented anything; once #16 lands and the retries default is fixed, autofail-succeeded G paths will start draining retries normally, narrowing this set to "the engine genuinely heard nothing"). This is the worker-side/engine-side ledger divergence (G intro) writ across the categories, with the activation timeout as the universal sweeper.

**H-style escapes can originate from any GRPC call site, not just `perform`.** Category H's at-a-glance shows the non-`StandardError` originating from `instance.perform`, but the escape pattern is identical regardless of where it's raised, as long as it propagates past `perform_job`'s `rescue StandardError`. A `SystemExit` raised mid-`complete_job` (e.g., a callback in user code called `Kernel#exit`) acts like H1 — `handle_success`'s `rescue StandardError` doesn't match either, so the SystemExit propagates through unchanged. Same for any non-`StandardError` from `fail_job` (in autofail or in user code) or `throw_bpmn_error`. Practical implication: H's "every ensure block fires" consequence applies uniformly; the originating site only changes which timestamps have already stamped and which intermediate state was captured before the escape began.

**`Busybee::StatusChangeOutsidePerform` in `shutdown_on` is silently a no-op (parallel to H4, different root cause).** Configuring `shutdown_on: [Busybee::StatusChangeOutsidePerform]` is structurally inert, but the H4 mechanism (the `rescue StandardError` boundary) isn't why — SCOP IS a `StandardError` subclass, and it does reach C13. The reason it's inert is the priority order in `handle_perform_exception`: the explicit `raise if exception.is_a?(Busybee::StatusChangeOutsidePerform)` at worker.rb:121 fires BEFORE the `shutdown_error?` check at line 122, so SCOP always re-raises past the wrap site regardless of `shutdown_on` membership. Same logic applies to `Shutdown` itself (also `StandardError`, also special-cased on the same line). The setter currently accepts both because the validator only checks the `StandardError` boundary, not the priority-order interaction. Tightening the validator to reject SCOP and Shutdown would convert these silent no-ops into explicit configure-time errors, mirroring the H4 mitigation; not yet tracked — open question whether it's worth the setter complexity for two edge cases.

**Hook-raised Shutdown during an ensure-block tail replaces the in-flight non-`StandardError`.** Ruby's `raise`-in-`ensure` semantics: when an exception is already unwinding and an ensure-block raises a new one, the new one *replaces* the in-flight exception entirely. The original is lost — no `cause` link, no record. Concretely: if `instance.perform` raises `NoMemoryError` (H1) and during the H1 tail an `on_job_executed` hook raises `Shutdown` (because `shutdown_error?` matched the hook's own underlying error), the Shutdown wins — the supervising process sees a `Busybee::Worker::Shutdown` propagating out of the runner, not the original `NoMemoryError`. The Job's error axis was never populated on the H1 path either (no early capture without C10), so the original `NoMemoryError` is fully invisible to postmortem investigation. Probably not worth fixing — `NoMemoryError` co-occurring with a Shutdown-class hook error is already a "this worker is going down hard" scenario — but worth knowing when reading a backtrace that ends in `Shutdown` and doesn't match anything you configured.
