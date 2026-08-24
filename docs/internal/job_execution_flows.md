# Job Execution Flows

Maintainer-facing reference tracing every salient moment in a job's execution from gRPC receive to runner-return. The document is organized into two top-level sections: **Typical Lifecycle** covers the four normal-operation variants (auto-complete, manual complete, autofail, manual fail / BPMN error), and **Lifecycle Edge Cases** covers the unusual paths (`Busybee::Shutdown` propagation, short-circuiting by resolving from a hook, GRPC call failures, and serious non-StandardError exceptions). Each variant is presented in two paired formats: a condensed at-a-glance summary, followed by a step-by-step walkthrough.

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
HOOK: before_perform (unsafe)
MIDDLEWARE: around_perform start (unsafe)
TIMESTAMP: perform_started_at
-- instance.perform starts --
```

**Walkthrough:**

1. GRPC CALL: A job is yielded from the workflow engine at one of the Runner receive points: `Polling#process_all_available_jobs`, `Streaming#run_inline`, `Streaming#pump_stream_into_buffer`, or `Hybrid#drain_backlog_while_also_processing_buffer`. At this point the workflow engine has marked the job activated.
2. `Runner#activate_job(job, source:, buffered:)`:
   - TIMESTAMP: `activated_at`.
   - `job.set_context(source:, buffered:, worker_class:)` — routes through Job's typed POROs; `source`/`buffered`/`worker_class` land on `Activation`. (Buffer *depth* isn't an Activation fact — it rides the `Worker::Status` stamped onto the job, as `current_buffer_size`.)
   - HOOKS: `on_job_activated` (safe — errors are logged and swallowed). This hook may resolve the job; doing so short-circuits it, and the trace continues as **Variant F**.
3. If the receive point is `Streaming#pump_stream_into_buffer`, the pump thread pushes the job onto `@job_buffer` and a consumer thread pops it. The Job carries all its state (POROs, timestamps, status) across the thread boundary.
4. `Runner#execute_job(job)`:
   - HOOKS: `around_job_execution` middleware, portions before yield (safe — errors are logged and swallowed; downstream still runs via the called-flag pattern in `Chain.build_safe`).
   - The chain descends unconditionally, even for a job step 2 already resolved: middleware brackets every job that was activated, and only the innermost gate decides whether work happens.
5. `Worker.perform_job(job)` (inside the core of the `around_job_execution` chain):
   - TIMESTAMP: `execution_started_at`.
   - `job.set_context(worker: instance)` — captures the worker instance on `Activation` so hooks can see it.
6. `run_hooked_perform(instance)` — **every step here is gated on `job.ready?`, asked afresh at each one.** The gates are what make the perform-like moments fire exactly when perform is attempted; a hook that resolves the job stops everything below it, and an invalid job stops at the first gate that follows validation.
   - GATE: `job.ready?` — false only if step 2 or step 4 already resolved the job.
   - VALIDATION: required inputs (errors here propagate, jumping to Variant C and failing the job).
   - GATE: `job.ready?`.
   - HOOKS: `before_perform` (unsafe — errors propagate, jump to Variant C, and fail the job, as if they were from inside perform). May resolve the job → **Variant F**.
   - GATE: `job.ready?` — false if `before_perform` just resolved, in which case the `around_perform` chain is not entered at all.
   - HOOKS: `around_perform` middleware, portions before yield (unsafe — errors propagate, jump to Variant C, and fail the job). May resolve the job → **Variant F**.
7. Inside the `around_perform` middleware chain core:
   - GATE: `job.ready?` — false if pre-yield middleware just resolved. The chain still descends to the core (forced continuation, `Chain.build_propagating`); this gate is what skips the work.
   - `timed_perform(instance)`:
     - TIMESTAMP: `perform_started_at`.
     - `instance.perform` runs — **this is the branch point.**

### Variant A — Auto-Complete (Happy Path)

At the branch point, `instance.perform` exits normally, returning a Hash (or anything else; non-Hash return values are coerced to `{}` later in `handle_success`).

**At a glance:**

```
-- instance.perform returns --
TIMESTAMP: perform_finished_at
-- result captured to Job --
MIDDLEWARE: around_perform finish (unsafe)
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
  - `capture_chain_result(target, raw_result)` (the innermost wrapper around the core block):
    - `resolution.set_result(raw_result)` — set-once, accepts only Hash values; coerces to a frozen `HashWithIndifferentAccess`. **Result is now set.** Non-Hash perform return values are silently rejected here and end up as `nil` on the Job (and `{}` in `handle_success`).

A9. Continuing `run_hooked_perform`:
  - HOOKS: Continuing `around_perform` middleware, portions after yield (unsafe — errors propagate, jump to Variant C, and fail the job).

A10. `handle_success(job, result, config)`:
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
    - HOOKS: `after_perform` via `Hooks.run(:after_perform, job, safe: true)` (safe — errors are logged and swallowed). Fires because `job.resolved?` and `perform_started_at` are both true — the job settled, and perform was actually attempted.

A13. Continuing `Runner#execute_job(job)`:
  - HOOKS: Continuing `around_job_execution` middleware, portions after yield (safe — errors are logged and swallowed).
  - execute_job's ensure block:
    - TIMESTAMP: `executed_at`.
    - Job counters increment; a fresh `Worker::Status` is re-stamped onto the job (completion-time counters and buffer gauges for the hook below).
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
MIDDLEWARE: around_perform finish (safe*)
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
  - `capture_chain_result(target, raw_result)`:
    - `resolution.set_result(raw_result)` — silent no-op (set-once; already set in B9). The raw perform return value is discarded.

B12. Continuing `run_hooked_perform`:
  - HOOKS: Continuing `around_perform` middleware, portions after yield (safe in this variant because the job is already complete — errors propagate to `perform_job`'s rescue, get logged as post-resolution, and the lifecycle continues at B13 below).
  - `handle_success(job, result, config)` exits early (no-op) because `!job.ready?`.

B13. Continuing `Worker.perform_job(job)`:
  - perform_job's ensure block:
    - HOOKS: `after_perform` via `Hooks.run(:after_perform, job, safe: true)` (safe — errors are logged and swallowed). Fires because `job.resolved?` and `perform_started_at` are both true — the job settled, and perform was actually attempted.

B14. Continuing `Runner#execute_job(job)`:
  - HOOKS: Continuing `around_job_execution` middleware, portions after yield (safe — errors are logged and swallowed).
  - execute_job's ensure block:
    - TIMESTAMP: `executed_at`.
    - Job counters increment; a fresh `Worker::Status` is re-stamped onto the job (completion-time counters and buffer gauges for the hook below).
    - HOOKS: `on_job_executed` via `Hooks.run(:on_job_executed, job, safe: true)` (safe).

Runner continues to the next job.

### Variant C — Auto-Fail (Perform Raises)

At the branch point, `instance.perform` raises some subclass of `StandardError`. This variant can also be reached from any of the "errors propagate, jump to Variant C" points elsewhere in the lifecycle: Common preamble (step 6: `validate_inputs!`, `before_perform`, `around_perform` middleware pre-yield), Variant A (A9: `around_perform` middleware post-yield; A10: `handle_success` output validations), and Variant B (B8: `Worker#complete!` output validations). **All secondary entry points land at step C10 — `perform_job`'s rescue is the common catch point; C8 and C9 describe the primary case where the error unwinds through `timed_perform` and the `around_perform` chain.**

**At a glance:**

```
-- instance.perform raises StandardError --
TIMESTAMP: perform_finished_at
-- around_perform middleware post-yield NOT run --
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
  - The error propagates past `capture_chain_result` (the innermost wrapper around the core block); no result is captured.
  - The error propagates through the chain: portions of `around_perform` middleware after yield **do not get run** (around_perform uses propagating semantics, not safe — errors short-circuit the rest of the chain).

C9. Continuing `run_hooked_perform`:
  - The error propagates through; the `handle_success` call does not run.

C10. Continuing `Worker.perform_job(job)`:
  - The error is rescued by `perform_job`'s `rescue StandardError`.
  - `handle_perform_exception(job, exception)`:
    - EARLY ERROR CAPTURE: `resolution.set_error(Shutdown.unwrap(exception))` — records the error on the error axis of Resolution before autofail runs, so `after_perform` sees the error attached to the Job even when autofail is disabled (C11) or its GRPC fails (C12). `Shutdown.unwrap` reduces a `Shutdown` to its `cause`; every other error passes through untouched.
    - Calls `handle_failure(job, exception, config)`.

C11. `handle_failure(job, error, config)`:
  - Exits early (no-op) if `fail_job_on_error` is off (autofail disabled — the original error surfaces in C13 via `log_unhandled_error`).
  - Exits early if the job is no longer `ready?` — reachable from the multi-variant interactions where Variant B's `complete!` or Variant D's `fail!`/`throw_bpmn_error!` succeeded before `instance.perform` raised. Logs inline via `log_post_resolution_error` and returns (no surfacing in C13 for this case).
  - Otherwise calls `attempt_auto_fail(job, error, config)`.

C12. `attempt_auto_fail(job, error, config)` → `job.fail!(Shutdown.unwrap(error), backoff: config.fail_job_backoff)`:
  - `Shutdown.unwrap` extracts a Shutdown's `cause` (or returns the error itself) so the engine sees the real failure cause, not the Shutdown wrapper. See **E5** for the full unwrap callout and **E3** for the inverse direction (where the Shutdown wrap is created in the first place).
  - Inside `fail!`: `resolution.set_error({error: ...})` — no-op (set-once on the error axis; already set by C10's early capture).
  - GRPC CALL: `client.fail_job(key, message, retries: <count - 1>, backoff: backoff)` — a bare fail sends one less than the current retry count (see the Retries accounting callout in Category G). **Workflow engine now sees the job as failed, with one retry drained.**
  - `resolve!(:failed)`:
    - TIMESTAMP: `resolved_at`.
    - STATUS CHANGE: `Resolution#resolve_to(:failed)` → `@status = :failed` (fire-once enforced).
  - If `job.fail!` itself raises (e.g., the fail-job GRPC also fails), `attempt_auto_fail` catches and logs the warning; execution continues normally back into `handle_perform_exception`. The error is still attached to the Job via C10's early capture.

C13. Continuing `handle_perform_exception`:
  - Re-raises if exception is `Busybee::Worker::Shutdown` (the one error special-cased to propagate past `perform_job`, since the worker declaring itself down outranks any per-job handling).
  - Wraps in `Shutdown.new(worker_class: self)` and raises if exception matches `shutdown_on` (per-worker or gem-level shutdown classes).
  - Otherwise: if `fail_job_on_error` is off, `log_unhandled_error(job, exception)` (this is where the early-return from C11's first case surfaces — the original error is recorded in the log).

C14. Continuing `Worker.perform_job(job)`:
  - perform_job's ensure block:
    - HOOKS: `after_perform` via `Hooks.run(:after_perform, job, safe: true)` (safe — errors are logged and swallowed). Fires when `job.resolved?` and `perform_started_at` are both true. Perform was attempted here, so resolvedness is the deciding half: true if `attempt_auto_fail` succeeded, false if autofail was skipped (C11) or its GRPC also failed (C12). When `:ready`, the Job still carries the error captured in C10; per-attempt observability for the unresolved case is `on_job_executed` at C15 (runner-level; fires for every job that reached `execute_job`, on all of its exit paths — but not for one the shutdown drain fails without running, see the Shutdown-path gap below). after_perform's contract is "the lifecycle reached a settled outcome the engine has on file."

C15. Continuing `Runner#execute_job(job)`:
  - If `perform_job` re-raised (or wrapped) a `Shutdown` in C13, it propagates through the `around_job_execution` chain. The chain is `safe: true`, but `safe:` governs *hook* errors only — an error arriving from below a link is marked on the way up and re-raised untouched, and the shared policy re-raises `Shutdown` in any case. The Shutdown therefore bubbles out of `Runner#execute_job` after the ensure block completes, and so does anything else that escapes `perform_job`. The chain's innermost boundary still classifies what passes through it: an escaping error matching `shutdown_on` becomes a `Shutdown` there even when no hook is registered.
  - Otherwise: HOOKS: Continuing `around_job_execution` middleware, portions after yield (safe — errors are logged and swallowed).
  - execute_job's ensure block (runs regardless of whether Shutdown bubbled):
    - TIMESTAMP: `executed_at`.
    - Job counters increment; a fresh `Worker::Status` is re-stamped onto the job (completion-time counters and buffer gauges for the hook below).
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
MIDDLEWARE: around_perform finish (safe*)
HOOK: after_perform (safe)
MIDDLEWARE: around_job_execution finish (safe)
TIMESTAMP: executed_at
HOOK: on_job_executed (safe)
```

For the `throw_bpmn_error!` variant, substitute `GRPC: job error (throw_bpmn_error, engine sees it as terminated by BPMN error)` and `STATUS CHANGE: -> error` in the lines above.

**Walkthrough:**

D8. `job.fail!(error)`:
  - `ensure_resolvable!("fail")` — the `ready?` check passes; nothing has resolved this job yet.
  - `message = format_error_message(error)` (formats Exception → `"[ClassName] message (caused by: ...)"`; strings pass through).
  - `resolution.set_error(error_data)` — error_data is `{error: exception}` for Exception args or `{error_message: string}` for non-Exception args. **Captures the error to Resolution before the GRPC, so the data is on Job even if the GRPC fails.**
  - GRPC CALL: `client.fail_job(key, message, retries: <count - 1>, backoff: nil)` — a bare `fail!` sends one less than the current retry count (see the Retries accounting callout in Category G); the nil backoff falls to `Busybee.default_fail_job_backoff` inside `Client#fail_job`. **Workflow engine now sees the job as failed, with one retry drained.**
  - `resolve!(:failed)`:
    - TIMESTAMP: `resolved_at`.
    - STATUS CHANGE: `Resolution#resolve_to(:failed)` → `@status = :failed` (fire-once enforced).

D9. Continuing `instance.perform`:
  - Any portion after `fail!(error)` runs normally; if perform later returns a Hash, that Hash is captured to `job.result` at D10. Errors here are safe — they propagate to `perform_job`'s rescue, get logged as post-resolution via `log_post_resolution_error` (C11's second early-return), and the lifecycle continues at D12 below.

D10. Continuing the `around_perform` middleware chain core:
  - Continuing `timed_perform(instance)`:
    - TIMESTAMP: `perform_finished_at`.
  - `capture_chain_result(target, raw_result)`:
    - `resolution.set_result(raw_result)` — set-once on the result axis. `result_set?` is false at this point because D8 touched only the error axis (`@error_set`); the result axis is untouched. If perform happens to return a Hash, that Hash is captured as `job.result` alongside the error data captured in D8. Non-Hash returns silently no-op. **This is intentional under Resolution's orthogonal model — the result axis records "what perform returned" and the error axis records "what perform signaled," and Variant D legitimately lands both (manual fail then a partial-payload hash for telemetry/audit). `after_perform` hooks can read both.**

D11. Continuing `run_hooked_perform`:
  - HOOKS: Continuing `around_perform` middleware, portions after yield (safe in this variant because the job is already failed — errors propagate to `perform_job`'s rescue, get logged as post-resolution, and the lifecycle continues at D12 below).
  - `handle_success(job, result, config)` exits early (no-op) because `!job.ready?`.

D12. Continuing `Worker.perform_job(job)`:
  - perform_job's ensure block:
    - HOOKS: `after_perform` via `Hooks.run(:after_perform, job, safe: true)` (safe — errors are logged and swallowed). Fires because `job.resolved?` and `perform_started_at` are both true (the manual setter resolved the lifecycle in D8, and perform ran).

D13. Continuing `Runner#execute_job(job)`:
  - HOOKS: Continuing `around_job_execution` middleware, portions after yield (safe — errors are logged and swallowed).
  - execute_job's ensure block:
    - TIMESTAMP: `executed_at`.
    - Job counters increment; a fresh `Worker::Status` is re-stamped onto the job (completion-time counters and buffer gauges for the hook below).
    - HOOKS: `on_job_executed` via `Hooks.run(:on_job_executed, job, safe: true)` (safe).

Runner continues to the next job.

## Lifecycle Edge Cases

The categories below trace what happens at the boundaries of the four typical-lifecycle variants. Sub-variants that differ only by originating site cross-link to a shared trace rather than duplicating prose — same convention as Variants A–D's "errors jump to Variant C" / "errors come in at C10 from A/B" cross-links.

**The Shutdown-path gap (not yet traced).** Every variant above enters through `Runner#execute_job`, whose ensure stamps `executed_at` and fires `on_job_executed`. A job that is activated but never executed skips both, and there is no trace here for that shape yet. Two routes reach it: `handle_shutdown_job`, which fails an in-hand job outright when `stopping?` (the polling loop, the inline stream, the buffer consumer, the hybrid drain, and the shutdown buffer sweep all call it); and `Streaming#kill!`, which clears the buffer, so those jobs are neither failed nor observed — they simply wait out their activation timeout engine-side. Both fire `on_job_activated` first, so **`on_job_activated` does not imply a matching `on_job_executed`** — a gauge paired across the two leaks by the in-hand count on every stop. Tracing these paths properly, and deciding whether the pairing should instead be made to hold, is open work.

### E. `Busybee::Worker::Shutdown` propagation

`Busybee::Worker::Shutdown` (a `Busybee::Error` < `StandardError`) signals that the worker process is unhealthy and must terminate. It propagates past every safe layer: `Hooks.classify_hook_error` — the shared policy behind both `Hooks.run(safe:)` and the safe chain — re-raises it before considering anything else, and a Shutdown travelling up from below a chain link is re-raised untouched in any case. Once Shutdown leaves `Runner#execute_job`, it bubbles to the Runner's run loop and terminates the runner thread.

**E1. Raised directly from `instance.perform`.**

**At a glance:**

```
-- instance.perform raises Shutdown --
TIMESTAMP: perform_finished_at
-- around_perform middleware post-yield NOT run (unsafe — Shutdown propagates) --
-- error captured to Job (early, via Shutdown.unwrap -> Shutdown.cause) --
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
  - MIDDLEWARE: `around_perform` finish (unsafe — Shutdown propagates through the chain; post-yield does NOT run).
  - The error is rescued by `perform_job`'s `rescue StandardError` (Shutdown < StandardError).
  - `handle_perform_exception(job, shutdown)`:
    - EARLY ERROR CAPTURE: `resolution.set_error(Shutdown.unwrap(shutdown))` — captures `shutdown.cause` (not the wrapper). See E5.
    - `handle_failure` → `attempt_auto_fail` → `job.fail!(Shutdown.unwrap(shutdown), backoff: config.fail_job_backoff)` (when `fail_job_on_error` and `job.ready?`):
      - GRPC CALL: `client.fail_job(key, message, retries: <count - 1>, backoff: backoff)`. **Workflow engine now sees the job as failed with the Shutdown's underlying cause, one retry drained.**
      - TIMESTAMP: `resolved_at`.
      - STATUS CHANGE: `Resolution#resolve_to(:failed)` → `@status = :failed`.
    - Explicit `raise if exception.is_a?(Shutdown)` re-raises past `perform_job`.
  - `perform_job`'s ensure block:
    - HOOK: `after_perform` via `Hooks.run(:after_perform, job, safe: true)` (safe — fires only when `job.resolved?`, i.e. autofail succeeded). The Job carries the early-captured error either way.
  - MIDDLEWARE: `around_job_execution` finish (safe — a Shutdown arriving from below is re-raised untouched, so middleware post-yield does NOT run).
  - `execute_job`'s ensure block:
    - TIMESTAMP: `executed_at`.
    - Job counters increment; fresh `Worker::Status` re-stamp.
    - HOOK: `on_job_executed` via `Hooks.run(:on_job_executed, job, safe: true)` (safe).
  - Shutdown bubbles out of `Runner#execute_job` to the Runner's run loop, which begins terminating.

**E2. Raised from an unsafe hook (`before_perform`, `around_perform` pre-yield, `around_perform` post-yield).**

The three origin sites converge on E1's "rescued by `perform_job`'s `rescue StandardError`" — from there, **the trace continues as E1**. The pre-rescue prefix differs per site:

  - From `before_perform` (flag set in Common 6): `Hooks.run(:before_perform, ..., safe: false)` re-raises via its explicit Shutdown clause. The around chain never starts; `perform_started_at` and `perform_finished_at` are NOT stamped.
  - From `around_perform` pre-yield (flag set in Common 6): `Chain.build_propagating` has no rescues at the middleware layer — Shutdown propagates straight out. The around chain's core block was never entered, so the core ensure (which re-sets the flag) does NOT fire. `perform_started_at` and `perform_finished_at` are NOT stamped.
  - From `around_perform` post-yield (flag re-set by the core ensure): `perform_finished_at` IS stamped (perform completed before the offending hook). The result axis may carry whatever `perform` returned — `capture_chain_result` ran in the core block before the ensure unwound into the offending middleware.

**E3. Triggered by `shutdown_on` match — a non-Shutdown `StandardError` matches the worker's `shutdown_on` configuration.**

Wrap site depends on origin:

  - **From perform or any unsafe hook surface** that propagates to `perform_job`'s rescue: `handle_perform_exception` runs as in C10–C13. After `handle_failure` runs autofail (the original error is not yet Shutdown — regular StandardError path), `Shutdown.triggered_by?(exception, self)` matches, and `raise Shutdown.new(worker_class: self)` fires (Ruby sets `cause` to the original). From here, **the trace continues as E1** from "MIDDLEWARE: `around_job_execution` finish".
  - **From a safe hook** (`on_job_activated`, `after_perform`, `on_job_executed`, `around_job_execution`): `Hooks.run`'s rescue checks `Shutdown.triggered_by?` inline and raises `Shutdown.new(worker_class: <the target's worker_class>)` directly, so the message names the worker that declared the error fatal. Hook iteration short-circuits. From here, **cross-link to E4** — propagation depends on hook site.

Important asymmetry: in the perform-side path, **autofail runs before the Shutdown wrap**, so the engine sees the underlying error via `fail_job` in addition to learning the worker is shutting down via the abandoned activation. In the safe-hook path, autofail does not run (it's only reachable from `perform_job`'s rescue).

**E4. Raised from a safe hook (`on_job_activated`, `after_perform`, `on_job_executed`, `around_job_execution`).**

`Hooks.run(safe: true)` and `Chain.build_safe` both have explicit `rescue Busybee::Worker::Shutdown; raise` clauses — Shutdown bypasses the swallow-errors logic at every layer. Surface point depends on origin site:

  - `on_job_activated`: raised inside `Runner#activate_job`. Propagates past the activate step, past whichever receive path activated this job (`Polling`, `Streaming`, `Hybrid`), into the Runner's run loop. The receive path's `executed_at` and `on_job_executed` for this job do NOT fire.
  - `after_perform`: raised inside `perform_job`'s ensure block. The `Hooks.run(:after_perform, safe: true)` rescue re-raises rather than logging. Shutdown emerges from `perform_job`. **The trace continues as E1** from "MIDDLEWARE: `around_job_execution` finish".
  - `on_job_executed`: raised inside `Runner#execute_job`'s ensure, after the runner-level safe around chain already completed. `executed_at` and the counter/status updates both happened before this point. Shutdown propagates past the receive path into the Runner's run loop.
  - `around_job_execution`: raised inside the runner-level safe around chain. `Chain.build_safe` re-raises Shutdown. Same downstream as E1's tail (Shutdown exits `Runner#execute_job` after the ensure runs).

**E5 (callout on C12).** What `Shutdown.unwrap` hands the engine.

  When `attempt_auto_fail` (or `handle_perform_exception`'s early-capture step) is called with a Shutdown wrapping a cause, `Shutdown.unwrap(shutdown)` returns `shutdown.cause` (or the Shutdown itself if no cause is set). This is what `fail_job` sends to the engine and what `set_error` captures on Resolution. The Shutdown wrapper is the framework's internal signal for "tear down the worker"; the engine and Resolution see the underlying cause. (See E3 for the inverse direction: the wrap site that creates the Shutdown in the first place.)

### F. Short-circuit: a hook resolves the job

A job hook may call `complete!` / `fail!` / `throw_bpmn_error!`. That is the supported way for a hook to short-circuit a job — an idempotency guard that finds the work already done, a circuit breaker that declines to try, a tenant paused for maintenance. The job resolves for real, on the wire, and everything downstream of the resolving hook that is *perform-like* stands down.

**The rule in one line: the chain always descends, and `ready?` decides whether work happens.** The middleware chain is never skipped and never cancelled — a hook that returns without calling `perform.call` gets a forced continuation and a warning, in both `Chain.build_safe` and `Chain.build_propagating`. What a short-circuit changes is not the shape of the traversal but whether each gated step finds anything left to do.

**Which moments are gated, and why those.** `validate_inputs!`, `before_perform`, the `around_perform` chain, and `timed_perform` each ask `job.ready?` at the moment they arrive; `after_perform` asks `job.resolved? && perform_started_at`. Together these give one invariant: **perform-like hooks fire exactly when perform is attempted.** Input validation is a precondition of the work, not a member of the perform triple, so an invalid job doesn't get the triple either (see the note at the end of this section). The system-lifecycle hooks — `on_job_activated`, `around_job_execution`, `on_job_executed` — are ungated and fire for every job that was activated, whatever became of it. They are where a short-circuited job is observed.

**Reporting.** `Worker.log_short_circuit` emits one `:info` line when the job settled without perform being attempted:

```
[busybee] Job <key> was resolved by a hook before perform ran; perform skipped
```

It fires from `run_hooked_perform`'s non-raising path, which is what separates a deliberate short-circuit from an invalid job — the latter leaves by way of `MissingInput` and is reported as a failure instead. There is no single gate every short-circuit passes through (skipping the `around_perform` chain means perform's own gate is never evaluated), which is why the line lives at the end of the method rather than at a gate.

**F1. From `before_perform`.**

**At a glance:**

```
HOOK: before_perform (unsafe) — calls job.complete!(vars)
GRPC: job completed (engine sees it as completed)
TIMESTAMP: resolved_at
STATUS CHANGE: -> complete
-- around_perform chain not entered --
-- perform not attempted; no perform_started_at --
-- after_perform does not fire --
LOG: info — perform skipped
MIDDLEWARE: around_job_execution finish (safe)
TIMESTAMP: executed_at
HOOK: on_job_executed (safe)
-- Runner continues to the next job --
```

**Walkthrough:**

  - Common 6's first gate passes (`ready?`), so `validate_inputs!` runs normally.
  - HOOKS: `before_perform`. The hook calls `job.complete!(vars)`; `ensure_resolvable!` finds the job `:ready` and permits it.
    - `resolution.set_result(vars)` — the result axis is unclaimed, so the hook's variables are what the engine receives.
    - GRPC CALL: `client.complete_job(key, vars:)`. TIMESTAMP: `resolved_at`. STATUS CHANGE: `-> complete`.
  - GATE: `job.ready?` is now false, so the `around_perform` chain **is not entered at all** — no pre-yield middleware, no core, no post-yield middleware.
  - `log_short_circuit(job)` fires: resolved, and `perform_started_at` is nil.
  - `handle_success` returns immediately (`job.ready?` is false), so there is no second completion.
  - `perform_job`'s ensure: `after_perform` does **not** fire — `perform_started_at` is nil, so perform was never attempted and no perform-like hook belongs here.
  - MIDDLEWARE: `around_job_execution` finish (safe) — unaffected; it brackets every activated job.
  - `execute_job`'s ensure: TIMESTAMP `executed_at`, counters, HOOK `on_job_executed` (safe).
  - Runner continues to the next job. No retry was consumed and no error was recorded: this was a completion, not a failure.

**F2. From `around_perform` pre-yield.**

The chain **was** entered (the gate before it saw a ready job), so the resolving middleware's own pre-yield code ran. Everything after it stands down: inner middleware links still run (the chain descends), but the core's own gate finds the job resolved and skips `timed_perform`, so `perform_started_at` is never stamped. Post-yield halves of every link run as normal — they are ordinary Ruby returning through the stack.

From here, **the trace continues as F1** from "`log_short_circuit(job)` fires".

Distinguishing detail: if the resolving hook returns *without* calling `perform.call`, the forced continuation runs the rest of the chain anyway and logs the "returned without yielding" warning. That warning is correct even though the short-circuit was deliberate — resolving is the idiom, skipping the yield is not, and the two are independent choices.

**F3. From `around_perform` post-yield.**

Perform ran and returned, so this is not a short-circuit at all — the work happened. Two things follow, and the second one surprises people.

  - `perform_started_at` **is** stamped, so `after_perform` fires normally and no `:info` line is emitted.
  - The chain's core already captured perform's return value onto the result axis, and that axis is **set-once**. A `complete!(vars)` here therefore transmits *perform's* result, not `vars`. That is the intended precedence — the work's own answer wins over a wrapper's — but the variables are silently dropped, so `Job#warn_discarded_result` logs:

    ```
    [busybee] Variables passed to complete! on job <key> were discarded: this job's
    result was already captured from perform's return value, and that is what the
    engine received
    ```

    The gem's own auto-complete is exempt: it hands back the very object it captured, so there is nothing to discard.

**F4. From `on_job_activated`, or `around_job_execution` pre-yield.**

The job is resolved before `Worker.perform_job` is ever called. `execute_job` still descends — the `around_job_execution` chain runs, `perform_job` runs — and every gate inside `run_hooked_perform` finds the job resolved, so **`validate_inputs!` does not run either**. That last part matters: without the gate, an invalid job that a hook had legitimately short-circuited would raise `MissingInput`, and `handle_perform_exception` sets the error axis unconditionally, so observers would see a failure that never happened.

From here, **the trace continues as F1** from "`log_short_circuit(job)` fires".

Thread note for `on_job_activated`: under buffered streaming this hook fires on the **pump thread**, so a resolution from it is a wire call from that thread. In practice the job then sits in the buffer before a runner thread takes it, so this is sequencing rather than a race; a hook that resolves *asynchronously* is a misuse we don't set out to catch.

**F5. Not a short-circuit: the invalid job.**

An invalid job (a required input absent) is not resolved by anyone — it raises `MissingInput` out of `validate_inputs!`, and the trace is **Variant C**, autofail. It appears here only because it shares the perform-like hooks' silence: `before_perform`, `around_perform` and `after_perform` all sit behind gates that a failed validation never reaches, so none of the three fires. That is the same invariant, not an exception to it — perform is not attempted, so nothing perform-like runs. The observation belongs to `around_job_execution` and `on_job_executed`, which fire as they do for every job, and to the engine, which learns of the failure through `fail_job`.

### G. GRPC call failures

Each resolution lifecycle method makes exactly one GRPC call: `complete!` → `client.complete_job`, `fail!` → `client.fail_job`, `throw_bpmn_error!` → `client.throw_bpmn_error`. All three go through the Client's `with_retry` wrapper (`client/error_handling.rb`), which optionally retries once at the client layer (`Busybee.grpc_retry_enabled`, off by default) and wraps `::GRPC::BadStatus` in `Busybee::GRPC::Error` (a `Busybee::Error` < `StandardError`; the BadStatus is chained as `cause`). A failed resolution call therefore surfaces to job-lifecycle code as an ordinary StandardError. Activation-side GRPC failures (the polling/streaming receive calls) happen before a Job exists and are runner-level concerns outside these traces; `update_retries`/`update_timeout` failures raise the same `Busybee::GRPC::Error` but touch no Resolution state — inside perform they behave like any other perform-raised StandardError (Variant C).

**Worker-side state vs. engine-side state.** `result` and `error` are worker-side records of what came out of executing the job; `status` is the engine's ledger *as reflected on this worker* — it advances only after the relevant GRPC call succeeds. The worker never observes engine state directly, so the two can diverge: `:failed` on the worker can pair with an incident on the engine, and `:ready` on the worker can pair with the engine still seeing the job as ACTIVATED (the engine-side name — visible in Operate and the Zeebe API — for what Busybee calls `:ready`). This split is the source of every G surprise.

Three design invariants govern every trace below:

1. **Outcome data is captured before the GRPC.** All three lifecycle methods call `resolution.set_result`/`set_error` *before* their GRPC call, so the Job carries the intended outcome even when the engine never learns of it.
2. **Framework-issued calls swallow; user-initiated calls propagate.** The framework's own resolution calls — auto-complete in `handle_success`, autofail in `attempt_auto_fail` — rescue GRPC failures internally, capture the error on Resolution for telemetry, log a warning, and continue (G1, G3). (Capture nuance: G1's rescue calls `set_error(e)` on the GRPC error since perform succeeded and there's no prior error to preserve; G3's rescue does NOT capture, because the original perform error was already early-captured at C10 and the error axis is set-once.) User-initiated lifecycle calls inside perform have no such rescue; the failure raises out of the perform call site and lands at C10 like any perform-raised error (G2, G4, G5). One consequence parallels E3's autofail-before-wrap asymmetry: only the propagating sub-variants reach C13's `Shutdown.triggered_by?` check, so configuring `Busybee::GRPC::Error` in `shutdown_on` converts G2/G4/G5 into E3 — while G1/G3's swallowed failures never reach the wrap site.
3. **G1 and G3 involve exactly one GRPC call.** G1 swallows the auto-complete failure entirely (no autofail attempted; `handle_success` rescues internally, before any rescue path that would route to `attempt_auto_fail`). G3 *is* the autofail's `fail_job`, and its failure is caught by `attempt_auto_fail`'s internal rescue. G2/G4/G5 involve a primary call plus an autofail attempt, so they fork along the two failure modes below.

**Two failure modes shape G2, G4, and G5.** The primary call fails; whether the autofail's `fail_job` *also* fails depends on what kind of outage we're seeing.

- **Correlated outage** (the realistic same-network failure mode — network down, broker unreachable, GRPC channel broken): the autofail's `fail_job` also fails. `attempt_auto_fail` swallows it; the job stays `:ready` worker-side, the engine still holds the activation, the activation times out, and the engine re-yields the job with its retries count fully intact (the engine never received any of the failed calls). `after_perform` stays silent (conditional on `resolved?`); `on_job_executed` is the per-attempt signal.
- **Isolated transient** (less common — a single call gets a `GRPC::Unavailable` or `GRPC::DeadlineExceeded` while the connection otherwise works): the autofail's `fail_job` succeeds. Worker-side, `:failed` is recorded. Engine-side, the failure lands normally: one retry drained, re-yield after the backoff, an incident only once the budget exhausts.

**Retries accounting on `fail_job`.** `Job#fail!` always sends a concrete count: an explicit `retries:` argument passes through verbatim (including `0`, which the engine treats as exhausted → immediate incident), and a bare `fail!` sends **one less than the current count**, where "current" honors an `update_retries` override when one was set (`Job#next_retries`). After the RPC, the sent value becomes the job's own `retries` reader, so worker-side state tracks the engine's ledger. Every *delivered* failure therefore drains exactly one engine-side retry until the budget hits zero and the engine raises an incident. (An earlier defect transmitted `retries: 0` on every bare fail — first failure, instant incident; `fail!` has since owned the decrement.)

Where each sub-variant lands:

| | Failing call | Handling | Worker-side state after | Engine's next move |
|---|---|---|---|---|
| G1 | `complete_job` (auto-complete, A) | logged + swallowed in `handle_success` | `:ready`; result set, error set (for telemetry) | activation times out → re-yield with retries intact |
| G2 | `complete_job` (manual `complete!`, B) | propagates to C10; autofail attempted | isolated transient: `:failed` with both axes set; correlated outage: `:ready` with both axes set | isolated transient: one retry drained, re-yield after backoff; correlated outage: re-yield with retries intact |
| G3 | `fail_job` (autofail, C) | logged + swallowed in `attempt_auto_fail` | `:ready`; error set (original perform error) | activation times out → re-yield with retries intact |
| G4 | `fail_job` (manual `fail!`, D) | propagates to C10; autofail retries the fail | same as G2 | same as G2 |
| G5 | `throw_bpmn_error` (manual, D) | propagates to C10; autofail attempts a *fail* | `:failed` (isolated transient) — **never `:error`** — or `:ready` (correlated outage); BPMN error data on error axis | same as G2 (engine never sees the BPMN error code; the error boundary is never reached) |

**A retry-budget asymmetry for at-scale operators to internalize.** A *delivered* autofail costs the job one engine-side retry; an *undelivered* one (correlated outage) costs none — the activation timeout re-yields with the count intact. So the more catastrophic failure mode (network down across many jobs) is also the one that leaves retry budgets untouched, while isolated transients drain them one attempt at a time.

**G1. `complete_job` fails during auto-complete (Variant A).**

**At a glance:**

```
-- instance.perform returns --
TIMESTAMP: perform_finished_at
-- result captured to Job --
MIDDLEWARE: around_perform finish (unsafe)
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
    - HOOK: `after_perform` NOT fired — `job.resolved?` is false. The job is `:ready` with **both** axes set: the canonical "result set does not imply success, and error set does not imply failure on the engine side" case under Resolution's orthogonal model.
  - MIDDLEWARE: `around_job_execution` finish (safe) — runs normally; nothing is propagating.
  - `execute_job`'s ensure block:
    - TIMESTAMP: `executed_at`.
    - Job counters increment; fresh `Worker::Status` re-stamp.
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
-- around_perform middleware post-yield NOT run --
-- error captured to Job (early in handle_perform_exception) --
-- autofail attempted (if fail_job_on_error and ready?) --
GRPC: autofail fail_job (engine sees it as failed, one retry drained)
TIMESTAMP: resolved_at
STATUS CHANGE: -> failed (worker-side; engine schedules the retry)
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
    - EARLY ERROR CAPTURE: `resolution.set_error(grpc_error)` — captures the *GRPC error* (`Shutdown.unwrap` passes non-Shutdown errors through). **Both axes are now set: the result perform intended to deliver, and the error that blocked delivery.** `after_perform` hooks can read both.
    - `handle_failure`: the job is still `ready?` (the manual complete never resolved), so `attempt_auto_fail` runs — `job.fail!(grpc_error, backoff: config.fail_job_backoff)`:
      - Inside `fail!`: `resolution.set_error(...)` — silent no-op (set-once on the error axis).
      - GRPC CALL: `client.fail_job(key, "[Busybee::GRPC::Error] ...", retries: <count - 1>, backoff: backoff)`.
      - **Isolated transient** (this `fail_job` succeeds): the engine records the failure — one retry drained — and re-yields the job after the backoff. The engine never learns the result hash, so the completed work is retried wholesale (an idempotency point for perform authors); the worker-side Job carries both result and error. `resolved_at` stamps; STATUS CHANGE: → `:failed` (worker-side); `after_perform` fires at C14. An incident arises only once the retry budget exhausts.
      - **Correlated outage** (this `fail_job` also fails — the realistic same-network case): `attempt_auto_fail` logs and swallows per C12; the job stays `:ready` worker-side; `after_perform` stays silent; the activation times out and the engine re-yields the job with retries fully intact (none of the failed calls reached engine state).
    - C13: `Shutdown.triggered_by?(grpc_error, self)` — if `Busybee::GRPC::Error` (or an ancestor) is configured in `shutdown_on`, the wrap fires and **the trace continues as E3** (perform-side path). Not matched by default.
  - The tail is C14–C15 unchanged.

**G3. `fail_job` fails during autofail (Variant C).**

No new trace shape — C12's closing bullet already covers the mechanics; this names the resulting state. Variant C runs unchanged through C12, where `attempt_auto_fail`'s internal rescue catches the `Busybee::GRPC::Error`, logs `"Failed to fail job #{job.key}: ... Job will timeout and retry."`, and swallows it. From there **the trace continues as C13** with the *original perform error* — the GRPC failure never escapes `attempt_auto_fail`, so it is invisible to C13's Shutdown/`shutdown_on` checks (the intro's swallow-vs-propagate asymmetry).

Resulting state: error axis set with the original perform error (C10's early capture — not the GRPC error); result axis unset; status `:ready`. `after_perform` silent at C14; `on_job_executed` fires at C15 as the per-attempt signal. The activation times out and the job is re-yielded — autofail's intended `backoff` never applied, and the engine's retry count is untouched.

**G4. `fail_job` fails during manual `fail!` (Variant D).**

Same shape as G2 with fail-side specifics. Begins at D8: `resolution.set_error(error_data)` — **error axis set with the user's intended error data before the GRPC** — then `client.fail_job` raises `Busybee::GRPC::Error`; `resolve!(:failed)` never runs; the job remains `:ready`. The GRPC::Error raises out of `fail!` at its perform call site, aborting the remainder of `instance.perform`; **the trace continues as Variant C from C8** and lands at C10.

Distinctive state at C10 (contrast G2):

  - EARLY ERROR CAPTURE: `resolution.set_error(grpc_error)` — **silent no-op.** The error axis already carries the user's intended error data from D8 (set-once). The Job permanently records what the worker meant to signal, not the transport failure that blocked it.
  - `attempt_auto_fail` retries the fail with the *GRPC error*: `job.fail!(grpc_error, backoff: config.fail_job_backoff)` — its internal `set_error` no-ops again.
  - **Isolated transient** (this `fail_job` succeeds): the engine records the failure — one retry drained — and re-yields after the backoff. The engine's failure message is the GRPC error's (`"[Busybee::GRPC::Error] ..."`) — the engine recording the transport failure is intentional signal for external monitoring, not noise — while the Job's error axis carries the user's original `fail!` data. The user's original `retries:`/`backoff:` arguments are silently dropped on autofail recovery (they live nowhere on the Job; autofail substitutes `config.fail_job_backoff` and the standard decrement).
  - **Correlated outage** (this `fail_job` also fails): same tail as G3 — `:ready`, `after_perform` silent, activation timeout, engine re-yields with retries intact.
  - Result axis: unset. Perform aborted at the `fail!` call site, so — unlike a successful Variant D — there is no D10 partial-payload capture (`capture_chain_result` is bypassed by the propagating error).
  - C13 `shutdown_on` interaction: same as G2.

**G5. `throw_bpmn_error` fails during manual `throw_bpmn_error!` (Variant D).**

Same shape as G4; the deltas:

  - The pre-GRPC capture is `resolution.set_error(bpmn_error_data(...))` — the error axis carries `error_code` and `error_message` (plus `error` when an Exception was passed) before the GRPC.
  - The recovery path is autofail, not a BPMN-error retry: the framework only knows how to auto-recover *failures*, not BPMN errors. The job resolves `:failed` worker-side — **never `:error`** — and the engine never sees the BPMN error code at all.
  - **Isolated transient** (autofail's `fail_job` succeeds): the engine records a plain failure — one retry drained, re-yield after backoff — so the BPMN error never reaches an error boundary in the process definition; the re-yielded attempt gets another shot at delivering it. The intended-but-undelivered BPMN routing is visible worker-side as the error axis's `error_code` alongside status `:failed`.
  - **Correlated outage** (autofail's `fail_job` also fails): `:ready` worker-side with `error_code` set on the error axis; engine re-yields the job for another attempt at perform, with retries intact. Hook surfaces can observe the undelivered BPMN intent on the unresolved job.

### H. Non-`StandardError` serious exceptions

"Safe" in this gem means **rescues `StandardError`**. It does NOT mean "rescues anything." Exceptions that descend from `Exception` without going through `StandardError` — `ScriptError` descendants (`SyntaxError`, `LoadError`, `NotImplementedError`), `NoMemoryError`, `SystemStackError`, plus the signal-control-flow classes `SignalException` (with descendant `Interrupt`) and `SystemExit` — bypass every rescue in the lifecycle, including the ones labeled safe. There are no explicit re-raise clauses for them anywhere in the gem because none are needed: a non-`StandardError` never matches the `rescue StandardError` in the first place, so it propagates implicitly.

**Two flavors worth separating, plus a third category that isn't really a "perform error" at all.** Deterministic developer errors (`SyntaxError`, `LoadError`, `NotImplementedError` — same input → same error on every attempt) are the *poison-pill* cases under today's behavior: a job that triggers them will trigger them again on every re-yield, retries never drain (activation timeout doesn't decrement engine-side retries; see Category G), and the job effectively eats activations forever. Situational unrecoverable errors (`NoMemoryError`, `SystemStackError`) are process-level conditions where even running autofail's `fail_job` would likely fail (the message allocation alone could OOM; the stack growth alone could overflow). The gem currently treats both alike — they all propagate out — but the operationally-correct behavior differs: deterministic errors deserve autofail-and-incident, the same as a deterministic `StandardError`, so the operator gets a clear signal in Operate; situational errors should propagate to the supervisor for a restart. Widening the rescue scope to capture the deterministic group (`ScriptError` family and similar) is tracked as future work; for now, both groups follow the same path below. The third category — signal-control-flow classes (`SignalException`, `Interrupt`, `SystemExit`) — isn't a perform error at all: the gem's CLI traps `INT`/`QUIT`/`TERM` at `cli.rb:46-50` and routes through `runner.stop!`, raising `Busybee::Worker::Shutdown` for in-flight jobs (Category E). A raw signal-class exception reaching the perform path is essentially unreachable under `bin/busybee` — it would require user code raising `Interrupt` directly, or someone embedding the runner without equivalent signal traps. For the traces below, treat `SyntaxError` / `LoadError` / `NoMemoryError` as the representative shapes.

Two consequences shape every trace below:

1. **Worker.perform_job's `rescue StandardError` does NOT catch.** `handle_perform_exception` does not run; no early error capture, no autofail, no `Shutdown.triggered_by?` check (and therefore no `Shutdown` wrap — Category E's perform-side path is unreachable from H). The error simply propagates out.
2. **Every `ensure` block still fires.** `timed_perform`'s ensure stamps `perform_finished_at`, the core block's ensure re-sets the status-change flag, `perform_job`'s ensure clears it defensively and checks `Hooks.run(:after_perform, job, safe: true) if job.resolved?` (false on H paths, so no fire), and `execute_job`'s ensure stamps `executed_at`, updates the counters and status snapshot, and fires `on_job_executed`. Observability of the abandoned activation survives.

Once a non-`StandardError` exits `Runner#execute_job`, it propagates past the runner's run-loop `rescue Busybee::Worker::Shutdown` (which matches Shutdown only) and into whatever process supervises the runner. That's outside per-job-lifecycle scope; H traces end at the `Runner#execute_job` exit.

**H1. Raised directly from `instance.perform`.**

**At a glance:**

```
-- instance.perform raises SyntaxError / LoadError / NoMemoryError / etc. --
TIMESTAMP: perform_finished_at
-- around_perform middleware post-yield NOT run (build_propagating has no rescues) --
-- error NOT captured to Job (perform_job's rescue StandardError does NOT match) --
-- autofail NOT attempted (handle_perform_exception did not run) --
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
  - MIDDLEWARE: `around_perform` finish — does NOT run. `Chain.build_propagating` (used for `:around_perform`) has no rescues at the middleware layer; non-`StandardError` propagates through the chain and after-yield code is skipped.
  - The error reaches `perform_job`'s `rescue StandardError` and **does NOT match**. EARLY ERROR CAPTURE does not run; `handle_failure` does not run; `attempt_auto_fail` does not run; the `Shutdown.triggered_by?` check at C13 is unreachable. The Job's error axis stays unset; the result axis stays unset (perform raised before capture_chain_result ran).
  - `perform_job`'s ensure block:
    - HOOK: `after_perform` NOT fired — `job.resolved?` is false.
  - MIDDLEWARE: `around_job_execution` finish (safe) — does NOT run. `Chain.build_safe`'s `rescue StandardError` does NOT match; non-`StandardError` propagates through.
  - `execute_job`'s ensure block (always runs):
    - TIMESTAMP: `executed_at`.
    - Job counters increment; fresh `Worker::Status` re-stamp.
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
  - `after_perform`: raised inside `perform_job`'s ensure block during `Hooks.run(:after_perform, job, safe: true)`. Non-`StandardError` emerges from `perform_job`; **the trace continues as H1** from "MIDDLEWARE: `around_job_execution` finish".
  - `on_job_executed`: raised inside `Runner#execute_job`'s ensure, after `executed_at` and the counter/status updates already ran. Non-`StandardError` exits `Runner#execute_job` directly and propagates as in H1's tail.
  - `around_job_execution`: raised inside the runner-level safe around chain. `Chain.build_safe`'s `StandardError`-only rescue doesn't catch. Same downstream as H1's tail.

**H4. `shutdown_on` with a non-`StandardError` class is rejected at configure-time (sanity check, non-trace).**

`Busybee.shutdown_on_errors` and the per-worker `shutdown_on` DSL both feed `Shutdown.triggered_by?(exception, self)` at C13 in `handle_perform_exception`. C13 is reachable only from `perform_job`'s `rescue StandardError`, which non-`StandardError` does not match — so a non-`StandardError` registered in `shutdown_on` would never reach the check at runtime. To prevent this silent-no-op footgun, both setters validate at configure-time: `Busybee.shutdown_on_errors = [Interrupt]` raises `ArgumentError`, and `shutdown_on Interrupt` inside a worker class body raises `InvalidWorkerDefinition`. The configuration knob is `StandardError`-bound by construction. Documented as a non-trace because there's no lifecycle path to draw — the invalid configuration never makes it past assignment.

### Cross-category interactions

A closing sweep of interactions across E/F/G/H that don't fit neatly into any one category. Most are structural observations or sub-findings; none warrant their own trace, but each is worth naming so a reader doing a cross-cutting investigation has them in one place.

**Engine-doesn't-know paths unify behind activation timeout.** Several lifecycle-edge paths share the property that the engine never receives a resolution signal — the safe-hook origins of E (E4), the correlated-outage variants of G2/G4/G5 (intro to G), every H path (H1/H2/H3). In all of them, worker-side state may advance to something settled (`:failed`, `:resolved?` true) or stay `:ready`, but engine-side state stays ACTIVATED until the activation timeout fires. The unifying recovery mechanism is the engine-side timeout, which re-yields the job as a fresh Job with retries intact (no `fail_job` reached the engine — a *delivered* autofail drains a retry, so this set is exactly "the engine genuinely heard nothing"). This is the worker-side/engine-side ledger divergence (G intro) writ across the categories, with the activation timeout as the universal sweeper.

**H-style escapes can originate from any GRPC call site, not just `perform`.** Category H's at-a-glance shows the non-`StandardError` originating from `instance.perform`, but the escape pattern is identical regardless of where it's raised, as long as it propagates past `perform_job`'s `rescue StandardError`. A `SystemExit` raised mid-`complete_job` (e.g., a callback in user code called `Kernel#exit`) acts like H1 — `handle_success`'s `rescue StandardError` doesn't match either, so the SystemExit propagates through unchanged. Same for any non-`StandardError` from `fail_job` (in autofail or in user code) or `throw_bpmn_error`. Practical implication: H's "every ensure block fires" consequence applies uniformly; the originating site only changes which timestamps have already stamped and which intermediate state was captured before the escape began.

**`Busybee::Worker::Shutdown` in `shutdown_on` is silently a no-op (parallel to H4, different root cause).** Configuring `shutdown_on: [Busybee::Worker::Shutdown]` is structurally inert, but the H4 mechanism (the `rescue StandardError` boundary) isn't why — `Shutdown` IS a `StandardError` subclass, and it does reach C13. The reason it's inert is the priority order in `handle_perform_exception`: the explicit `raise if exception.is_a?(Shutdown)` fires BEFORE the `Shutdown.triggered_by?` check on the following line, so a Shutdown always re-raises past the wrap site regardless of `shutdown_on` membership — which is harmless, since propagating is what it was going to do anyway. The setter accepts it because the validator only checks the `StandardError` boundary, not the priority-order interaction. Tightening the validator would convert this silent no-op into an explicit configure-time error, mirroring the H4 mitigation; not yet tracked — open question whether it's worth the setter complexity for one edge case.

**Hook-raised Shutdown during an ensure-block tail replaces the in-flight non-`StandardError`.** Ruby's `raise`-in-`ensure` semantics: when an exception is already unwinding and an ensure-block raises a new one, the new one *replaces* the in-flight exception entirely. The original is lost — no `cause` link, no record. Concretely: if `instance.perform` raises `NoMemoryError` (H1) and during the H1 tail an `on_job_executed` hook raises `Shutdown` (because `Shutdown.triggered_by?` matched the hook's own underlying error), the Shutdown wins — the supervising process sees a `Busybee::Worker::Shutdown` propagating out of the runner, not the original `NoMemoryError`. The Job's error axis was never populated on the H1 path either (no early capture without C10), so the original `NoMemoryError` is fully invisible to postmortem investigation. Probably not worth fixing — `NoMemoryError` co-occurring with a Shutdown-class hook error is already a "this worker is going down hard" scenario — but worth knowing when reading a backtrace that ends in `Shutdown` and doesn't match anything you configured.
