# Changelog

## Unreleased

Instrumentation hooks for every job, worker and gRPC call, with testing helpers to match, structured logs, and a guide to operating busybee in production.

### New Features:

- **Lifecycle Hooks** – Attach your own code to every moment of a job, a worker and each gRPC call, as middleware (transactions, retries) or as observation (metrics, tracing, error reporting), wired into whichever APM or error reporter you run: Datadog, New Relic, Dynatrace, Airbrake, Sentry and the like:
  - Job moments, from the system's view: `on_job_activated`, `around_job_execution`, `on_job_executed` and `on_job_not_executed`; and around your own code: `before_perform`, `around_perform` and `after_perform`
  - Worker moments, for each worker: `on_worker_started`, `on_worker_stop_requested`, `on_worker_stopping` and `on_worker_shutdown`
  - Call moments: `before_call`, `around_call` and `after_call`, around every gRPC call
  - Each callback receives a lifecycle object carrying what that moment knows: status, gauges, counters, timestamps, durations and configuration
  - Two ready-made projections: `context_tags`, low-cardinality, for metric labels, and `logging_context`, for structured logs. The logging projection names an error by its class and message, and a job's never carries what `perform` returned, so logging it whole keeps workflow-instance data out of your logs
  - Middleware sees what the work produced: `perform.call` returns the job's result in every around hook, so a span or a log line can carry it without reaching back into the job
  - `raise Busybee::Worker::Shutdown, "read replica has fallen too far behind"` declares the worker unhealthy from any hook, with no underlying error needed, stopping the worker gracefully as `reason: :unhealthy`
  - An error matching `shutdown_on` does the same from a job hook as from `perform`. A call hook escalates only on the gem-wide `Busybee.shutdown_on_errors`, and the teardown hooks (`on_worker_stop_requested`, `on_worker_stopping`, `on_worker_shutdown`) record the error for `on_worker_shutdown`'s `status.error` instead
  - The hook-error policy covers errors a hook raises, and nothing more. An error from the work a hook wrapped is the job's business or the caller's, and an error inside busybee itself surfaces where it happened rather than being logged as a fault in your hooks. See "What the Swallow Doesn't Cover" in the hooks guide for reading an outcome off the lifecycle object instead of rescuing around the call

- **Hook Filters, Checked at Boot** – Register a hook only for the cases you care about, such as an `after_perform` for failed jobs only, by matching attributes of the lifecycle object:
  - Match by a literal, a Regexp, a Class, a Proc, or an array of any of them. Strings and Symbols are interchangeable, so `status: "failed"` and `status: :failed` are one filter and neither spelling quietly misses
  - A filter that could never fire is refused at boot, with a message saying why: a mistyped status, an RPC busybee never issues, or an outcome filter on a hook that runs before the outcome exists (`around_call` sees a pending call, never a succeeded one). The hooks guide publishes the full table of what each hook can already know when it fires

- **Call Hooks That Shape the Request** – Rewrite the outbound request in `before_call` before it reaches the engine: scrub an exception message that may carry customer data, decline a BPMN retry when it was your infrastructure that failed rather than the job, or send your own correlation id along. Written once, it applies to every call of that kind, so there is no call site left to forget
  - A request is sealed the moment it is sent, so what `after_call` reports is exactly what the engine received
  - A retry begins from a fresh writable copy of what the previous attempt sent, so a rewrite in `around_call` applies to the retry as well as the first try
  - A client call made from inside a call hook is refused with `Busybee::ReentrantCall`, so an `after_call` that publishes an alert can't set itself off. Job and worker hooks may use the client freely

- **Perform Hooks That Fire When Your Code Runs** – `before_perform`, `around_perform` and `after_perform` fire exactly when `perform` is attempted, so a job short-circuited by a hook or turned away by input validation never reaches them. `on_job_executed` fires for every job the worker ran, short-circuited or not, and is the place for observation that must not miss one
  - `after_perform` is an `ensure` on your code: it runs however the attempt turned out, after automatic completion and failure, so `status` and `error` are already on the job when you read them
  - That includes the attempts that didn't settle the job: a resolution call that never reached the engine, or a `perform` that handed the work to a background thread. A job arriving with `status == :ready` is still yours to settle, and you can resolve it from the hook
  - So `after_perform(error: SomeError)` also sees the error that stopped a resolution, typically a `Busybee::GRPC::Error` from a failed `complete_job` or `fail_job`; give such a hook a `job.resolved?` check if it assumes the job settled. Filters on a settled outcome (`status: :complete`, `:failed`, `:error`) see settled jobs only
  - An error raised by any of the three takes the path an error from `perform` takes: if the job is unresolved, it fails and the engine is told; if it already settled, the error is logged against the job; and `shutdown_on` still escalates. An invalid output offered from a hook therefore reaches the engine
  - An `around_perform` that returns without calling `perform.call` still runs the rest of the chain, and logs a warning, as `around_job_execution` does. To skip the work, resolve the job instead (below)

- **Short-Circuit a Job From a Hook** – Sometimes the right answer is "don't do this work": the job was already fulfilled by an earlier attempt, the downstream service is in a known outage, the tenant is paused for maintenance. Resolve the job from any job hook with `complete!`, `fail!` or `throw_bpmn_error!`, and busybee stands down: `perform` doesn't run, input validation doesn't run, and neither automatic completion nor automatic failure fires against a job the engine already considers finished
  - Keep calling `perform.call` from your middleware exactly as you always have: the chain always descends, and busybee skips the work for you
  - `on_job_activated`, `around_job_execution` and `on_job_executed` bracket every job the worker ran, short-circuited or not, so your instrumentation still sees it happen. A job handed back at shutdown gets `on_job_not_executed` instead
  - Resolving a job that is already resolved still raises `Busybee::JobAlreadyHandled`
  - A skipped `perform` is logged at `info`, and `complete!` tells you when variables you passed were discarded in favor of a result `perform` had already returned

- **Shutdowns Your Instrumentation Can Count On** – The worker and job brackets close on every graceful shutdown, so gauges and counters stay true across a deploy:
  - **`on_job_not_executed`** closes the bracket for a job your worker took delivery of but never ran, because a shutdown reached it first. Exactly one of it and `on_job_executed` fires for every activated job, so an in-flight gauge comes back to zero across a deploy
  - The job goes back to the engine unworked: retries untouched, `status` still `:ready`, nothing reported as failed
  - That includes a job whose own `on_job_activated` hook declared the worker unhealthy: it goes back at once instead of waiting out its activation
  - Every run passes all four worker moments in order, each exactly once, even a run a crash ended without anyone asking it to stop, which still fires `on_worker_stop_requested`. `on_worker_stopping` waits for that hook even when another thread is running it, for up to `shutdown_wait_timeout`
  - Teardown hooks can't derail the shutdown they watch: declaring the worker unhealthy from `on_worker_stop_requested`, `on_worker_stopping` or `on_worker_shutdown` is recorded and handed to `on_worker_shutdown` on `status.error` while the shutdown finishes. Jobs in hand still go back, later hooks still fire, and the exception the worker is exiting on stays the one you see
  - The closing hooks say how the worker really went down, whichever thread the trouble struck. An error the process can't recover from ends the worker `:crash`, never an ordinary close by the engine, with the error on `status.error` wherever a closing hook still runs
  - A gateway failure, a worker declared unhealthy, or any error on a streaming worker's stream reader, arriving once a graceful stop is under way, lets that stop finish as one: its reason stands, and the error is logged and reaches `on_worker_shutdown` as `status.error` instead of being raised. When that error is outside `StandardError`, the `busybee` command exits with status 1 and logs why, so your orchestrator sees a failed container and you can see what failed it
  - An error the process can't recover from, such as a `NoMemoryError`, raised in a teardown hook tells every worker in the process to exit without handing more jobs back, then crashes the process. On a streaming worker's stream reader it reaches `on_worker_shutdown` instead, and the `busybee` command exits with status 1, logging why
  - Two shutdowns leave jobs not yet started to the engine's activation timeout, and may skip hooks, closing hooks included, to get out fast: a forced `kill!`, and any error outside `StandardError`, such as a `NoMemoryError` or a `NotImplementedError`

- **Choose What Counts as Backpressure** – `Busybee.backpressure_statuses` (default `[:resource_exhausted]`) names the gRPC status codes that mean the gateway is applying backpressure. When a job-activation call resolves to one of them, polling and hybrid workers back off for `backpressure_delay` and retry the fetch, matched by status code whichever gRPC exception class the gateway raised. In a Rails app, set it as `config.x.busybee.backpressure_statuses`

- **Tunable Shutdown Waits** – `shutdown_wait_timeout` (default 5 seconds) sets how long a stopping worker waits for its other threads to finish their part of the shutdown, such as a streaming worker's stream reader still inside a slow hook, before carrying on without them
  - One value serves the whole process: set `Busybee.shutdown_wait_timeout` (`config.x.busybee.shutdown_wait_timeout` in Rails), or a top-level `shutdown_wait_timeout` in YAML, which, like the `busybee` command's flags, gives way to a value your app sets itself

- **Dropped Connections Can't Stall a Stream** – HTTP/2 keepalive pings guard the streaming worker's job-activation stream, which has no deadline of its own, so a silently dropped transport (a suspended host, a connection a proxy reset) surfaces as a recoverable gateway error instead of leaving the worker blocked forever
  - On by default; tune with `Busybee.grpc_keepalive_interval` (default 45 seconds) and `Busybee.grpc_keepalive_timeout` (default 20 seconds), or set both to `false` to disable

- **Structured Logs** – Every line Busybee writes follows your `log_format` and starts with `[busybee]`, so one parser handles them all. Lines that used to arrive as plain text even under `:json`, such as a failed completion, a job handed back during shutdown or a worker crashing in a multi-worker process, are JSON now
  - In JSON, a line carries the `logging_context` of the job, worker or call it concerns, and an error's `error_class` and `error_message`, so you can filter on `job_key` or `worker_class` instead of parsing messages
  - In text, a line reads on its own, ending with the error when there is one: `Failed to complete ship_order job #2251799813685292, will time out and retry (Busybee::GRPC::Error: GRPC call failed (connection lost))`
  - Ordinary conditions are logged too, at `info`: each worker's start and stop, and each job's completion, failure, BPMN error and handback; and, at `debug`, each job's activation. That is a line or two per job, so set your logger's level to `warn` to quiet them
  - Every JSON line carries a `time` field (ISO8601 UTC, millisecond precision), so structured logs stay self-ordering even where the host logger's formatter, which normally supplies the timestamp, is bypassed or absent
  - Logging doesn't disturb your workers: a logger that fails to write leaves them running, and Busybee reports the failure on stderr instead, unless the failure is one the process can't recover from, such as running out of memory, which shuts the process down like any such failure would
  - Existing lines were reworded to name the job or worker they concern; if you match on Busybee's log text, check your patterns

- **Durations, Written However Reads Best** – Anywhere Busybee takes a length of time (client call arguments, gem-level configuration, the worker DSL, YAML, keepalive), write it the same way: a bare number for milliseconds, an `ActiveSupport::Duration` in whatever unit reads best, or a numeric String, handy for `ENV`-sourced config. Write `30.seconds` and stop counting zeroes
  - Fractions are kept as written and truncated to whole milliseconds only where a value reaches the wire, so `buffer_throttle: 0.1` means what it says
  - Every setting that takes a duration accepts every one of these shapes, the worker DSL, `buffer_throttle` and `polling request_timeout:` included, where each used to read its values a little differently
  - A `Duration` reaches the wire and the worker's own backoff at its true length, not a thousand times too fast

- **A Warning When a Duration Looks Like a Units Slip** – A bare number means *milliseconds*, which makes `default_message_ttl = 30` a message that expires in thirty thousandths of a second. Busybee notices and tells you exactly what to write instead:

  ```
  [busybee] default_message_ttl: 30ms seems unusually small for this setting. Durations here are
  milliseconds; if you meant 30 seconds, use 30000 or 30.seconds
  ```

  Your value is still applied. Deliberately tiny settings stay quiet: `0` means "no delay", `-1` is Zeebe's "answer immediately" for `request_timeout`, and `buffer_throttle`, which takes sub-millisecond values, never warns. Per-call arguments, such as a one-off `ttl:`, never warn either

- **The Client, Right From `perform`** – Make any other gRPC call from inside your worker, such as updating retries or publishing a BPMN message, through `client`, which delegates to `job.client`: the `Busybee::Client` that delivered the job

- **Strict Output Validation** – Keep undeclared data out of your workflow engine: a worker's outputs must match its `output` declarations, and an undeclared key raises `Busybee::UndeclaredOutput`
  - Applies to automatic completion and to `complete!`, whether through the worker or `job.complete!`, whenever a worker is attached to the job. A `Busybee::Job` used on its own has no declarations to check against
  - Opt out per worker with `strict_outputs false`, or gem-wide with `Busybee.default_strict_outputs = false`
  - **On by default,** which is a breaking change; see below

- **Testable Hooks** – Put the hooks you register under test at every level: worker, job, `perform` and call. `execute_worker` runs your worker the way a worker process does (it starts, activates and executes the job, and shuts down), so every hook you registered fires in the order production fires it, with no Zeebe and no network
  - Ask what your hook code does at one moment, without running a worker: `fire_busybee_hooks(:on_job_executed, build_test_job(type: "ship_order", status: :failed))` runs every hook registered for that moment whose filters accept the job, so one example covers both the wiring (does my filter pick this job?) and the effect (does my metric go up?). Around hooks wrap the block you pass; worker moments take a status or a test worker
  - Subtract what a spec isn't about with `without_busybee_hooks(:job, :worker, :call) { ... }`, naming the word in the hooks' names, or with `without_busybee_hooks:` metadata on a group or file. Your `perform` hooks keep wrapping `perform`, so a transaction middleware still applies to the worker it protects
  - Hold the worker open to test its lifecycle directly: `start_test_worker(ShipOrderWorker)` fires `on_worker_started`, `execute_worker(worker, jobs: [...])` runs jobs through it, and `worker.stop!` fires the closing moments
  - `build_test_client` hands you a genuine `Busybee::Client` with an in-process transport: the call seam, the retry and the carrier your hook receives are all the real machinery, and only the socket is gone. Resolve a job through it and your `before_call`, `around_call` and `after_call` run exactly as they do in production
  - Program what the broker does, to test the paths a healthy one never takes: `client.on(:complete_job) { raise GRPC::Internal, "storage unavailable" }`. The block *is* the handler, so return a response message for success and raise a `GRPC::BadStatus` subclass for a failure, the same vocabulary a real gateway speaks
  - `client.received(:publish_message)` reads back what actually reached the wire, so "did my worker send that?" needs no programming first
  - Builders for the other two carriers, to test a hook body on the object it will be handed: `build_test_worker_status(worker_class: ShipOrderWorker, total_job_count: 7)` and `build_test_call(:complete_job, job: job)`. They build what busybee builds, so `context_tags` and `logging_context` are computed, never written down by the test, and your assertions follow the real key set when it moves
  - `build_test_job` composes with them and with the activation facts your filters match on (`worker_class:`, `worker_status:`, `source:`, `buffered:`), and can hand back a job that already resolved (`status: :complete`) by driving the real resolution. A job built without `source:` has none, since no transport delivered it, so a hook filtered on `source:` fires only when you pass one
  - `build_test_job` takes `key:` for a stable, known job key, such as for correlating one job across several assertions; it defaults to a random integer
  - Building a fixture never fires your hooks, so setup cannot pollute what the example is about to observe, and `isolate_busybee_hooks { ... }` puts the hook registry back when the block ends, so observers a spec registers can't leak into the next example

- **Wait for Every Job a Step Creates** – `activate_jobs(type, expected: 3)` waits until all three jobs are in hand, such as one for each element of a parallel multi-instance collection. No more `sleep` before activating, and no spec that passes having completed only the jobs that happened to exist yet
  - If the wait runs out first, it raises `NoJobsAvailable`, saying how many arrived
  - It asks the engine only for the jobs it still needs, so it returns exactly three and leaves any others there: add `expect { activate_job(type) }.not_to have_available_jobs` to check there are no more
  - `max_jobs:` is its mirror image: it succeeds even when fewer are available, none included
  - The error is now `Busybee::Testing::NoJobsAvailable`, matching `activate_jobs` and `have_available_jobs`, and it shares a base class, `Busybee::Testing::Error`, with the testing helpers' other errors. Its former name, `NoJobAvailable`, still works, so your rescues and `raise_error`s need no change

- **A Guide to Operating Busybee** – A new page, `docs/operating.md`, for whoever runs the `busybee` command in production: what it logs, what its exit status means, how long it takes to stop and how to size the grace period, what to probe for health, and where to look when a worker goes quiet, illustrated with log lines from real runs

- **Docs for the Version You Run** – Busybee's documentation lives on GitHub, and the gem's RubyGems page links the docs for the version you installed (`documentation_uri`). The gem itself no longer ships them

### Bug Fixes:

- **Workers Survive Gateway Backpressure** – A gateway reporting `RESOURCE_EXHAUSTED` to a polling or hybrid worker used to crash it, and in a multi-worker process took every sibling worker down with it, so a fleet-wide broker slowdown became a fleet-wide outage. The error, which arrives while job activation's responses are being read, escaped untranslated past the rescue meant to catch it. It now reaches the worker as a `Busybee::GRPC::Error` with `grpc_status` intact, so the documented backoff-and-retry runs and the process stays up
  - `Client#with_each_job` now keeps the `Busybee::GRPC::Error` contract its documentation promises, whatever status the gateway returns

- **Backoff and Retry Delays Wait the Length You Configured** – Three settings were measured in milliseconds on the way in and then slept as though they were something else, so none of them waited what you asked for:
  - `backpressure_delay` parked a worker for its value in **seconds**: the default of `2_000` meant a worker vanished for over half an hour on a single backpressure event, and the documented `10_000` example for nearly three hours. It now waits two seconds
  - `grpc_retry_delay` and `buffer_throttle` had the opposite fault, and only when set with an `ActiveSupport::Duration`: `grpc_retry_delay = 0.5.seconds` retried after half a *millisecond*. Both now honor a `Duration` exactly as they honor a number
  - A sub-second `Duration` no longer rounds to zero on its way to a wait, so `0.25.seconds` means a quarter second rather than no pause at all

- **Extending a Job's Lock in a Test Accepts a Duration** – The testing module's `update_timeout` read an `ActiveSupport::Duration` as a bare number, so `job.update_timeout(5.minutes)` asked the engine for 300 *milliseconds* and the lock lapsed immediately. It now reads a length of time the way everything else in the gem does

- **Job Matchers Accept a Regexp or Any Matcher** – The matchers `have_received_variables` and `have_received_headers` compared each expected value by equality, so `have_received_variables(payment_id: /\Apay-/)` could never pass, though `expect_variables` beside it took the same argument. Both now read an expected value the way RSpec's `include` does: a Regexp, or any matcher, such as `a_value > 0`

- **Workflow Tests Leave No Instance Behind, Nested or Not** – Each `with_process_instance` block now cancels its own instance, so nesting one inside another no longer leaves the outer instance running for later examples to trip over:
  - Once an inner block ends, the outer instance is current again, so `process_instance_key` and `assert_process_completed!` check the instance you're in. Before, `assert_process_completed!` there could pass while the outer instance was still running
  - An inner block whose instance fails to start no longer cancels the outer one, and an inner `with_activated_job_instance` that finds no job no longer completes the outer block's job
  - When a cancel fails after your example has already failed, your example's own failure is the one you see, with a warning on stderr naming the instance left running
  - `assert_process_completed!` outside `with_process_instance`, where there is no instance to check, raises `Busybee::Testing::NoCurrentProcessInstance` instead of passing

- **`not_to have_available_jobs` No Longer Passes on an Error** – The matcher read any error in its block as "no jobs", so `expect { activate_job("x") }.not_to have_available_jobs` passed on an unreachable gateway, a bad argument or a failed expectation inside the block
  - Any error but `NoJobsAvailable` now raises through it, in either form, and a failure carries the error's message, such as how many of the expected jobs arrived
  - An empty result from `activate_jobs(max_jobs:)` counts as no jobs, where it used to satisfy `to have_available_jobs`

- **A Failing Worker Can No Longer Take a Container Down Quietly** – In a multi-worker process, a worker dying of something outside the ordinary error hierarchy (a `NoMemoryError`, or the stack exhaustion left by a runaway recursion) left no trace at all: nothing logged, no sibling shutdown, and a process that could no longer even exit, so that job type simply stopped being worked until someone redeployed
  - Such a failure is now logged with the worker it came from, stops the remaining workers, and ends the process with the original error
  - Its workers skip the graceful drain, making no more network calls from a process in that state, and the engine reclaims their jobs on activation timeout

- **A Deploy's Shutdown Stays Graceful** – A worker already stopping for a deploy's SIGTERM, which then met a gateway error on a fetch or was declared unhealthy by a job, exited raising that error, so a routine deploy read as a crash. It now finishes the graceful stop it was making, logs the error as a warning and reports it to `on_worker_shutdown` instead
  - A worker backing off from gateway backpressure stops waiting as soon as it is told to stop, rather than sitting out the rest of `backpressure_delay`

- **A Streaming Worker Stops Even While It Connects** – A stop that arrived while a streaming worker was still opening its job stream found nothing to close yet, so a worker with buffering off waited for the next job before stopping, which on an idle job type meant indefinitely, and its process never exited. It now stops at once

- **An Unreachable Gateway Reads as a Gateway Error** – A streaming or hybrid worker that couldn't reach the gateway as it opened its job stream raised a raw `GRPC::Unavailable` that slipped past every `rescue Busybee::GRPC::Error`, so a gateway outage at startup looked like a bug in your code
  - `Client#open_job_stream` now raises a `Busybee::GRPC::Error` with `grpc_status` intact
  - The worker stops as `:gateway_error`, as a polling worker does, so `on_worker_shutdown(reason: :gateway_error)` and the alerts you filter on it catch the outage
  - The `busybee` command still exits with status 1, so your orchestrator restarts it as before

- **A Worker Whose Stream Ends Takes the Process Down With It** – In a multi-worker process, a worker that stopped on its own, most often because the engine closed its job stream, simply ended while the others ran on, so its job type went unworked until someone restarted the process, and a process whose workers all ended that way never exited. Now the rest stop with it, gracefully and under the same reason, so the process exits and your orchestrator replaces it

- **A Forced Shutdown Says What It Threw Away** – `kill!`, the forced stop behind a second termination signal, discarded whatever jobs were still buffered without a word. It now logs how many it dropped before the process goes. That line is the record: the stop reason already belongs to the graceful stop, and the immediate exit may skip every shutdown hook

- **Rails Settings Apply Whichever Loads First** – Requiring busybee before Rails skipped its Railtie, so every `config.x.busybee` setting was silently ignored. The setup instructions led straight there: `require "busybee/testing"` in a `spec_helper.rb` loads before Rails boots, so a test suite could run without the retry, timeouts or cluster address you configured. The Railtie now loads whenever Rails does, whichever of the two you require first
  - Earlier versions of these docs set `config.x.busybee` in `config/initializers/busybee.rb`. That never took effect: the Railtie reads it before your initializers run. Set it in `config/application.rb` or `config/environments/*.rb`, or call `Busybee.configure` from the initializer instead

- **Rails Config No Longer Overwrites Settings It Doesn't Mention** – Whenever `config.x.busybee` set anything at all, the Railtie reset `cluster_address` and `worker_name` to their defaults unless it set them too, wiping a value you had configured on Busybee directly before Rails booted, and it always replaced a logger configured that way with `Rails.logger`. It now applies only the settings you give it, and a blank value (an empty environment variable, say) doesn't count as given
  - A logger you set before Rails boots stays, `nil` included, so `Busybee.logger = nil` in `config/application.rb` now keeps Busybee quiet instead of handing it `Rails.logger`

- **A Rails App That Fails to Boot Stops the `busybee` Command** – When your app raised while loading, `busybee` logged the error where it usually went unseen, carried on without your app, and then failed with a `WorkerNotFound` for a worker that was never the problem. It now logs why and exits with status 1, with the error's backtrace on stderr, so your orchestrator sees a failed boot and you see the line that failed. A syntax error or a missing gem in your app stops it the same way:

  ```
  [busybee] Failed to load Rails environment in /srv/app; set BUSYBEE_SKIP_RAILS=1 if this is not a Rails app (KeyError: key not found: "DATABASE_URL")
  ```

  - A bundle without Rails still skips it silently. A bundle with Rails, run where there's no `config/environment.rb`, logs `Continuing without Rails, no config/environment.rb in <dir>` and carries on. Set `BUSYBEE_SKIP_RAILS=1` to skip Rails altogether
  - `busybee` now logs to stdout from its first line, at `info`, until your app's logger takes over, so what Busybee says while your app boots is no longer lost. Outside Rails, with no logger of your own, its lines go there for the whole run; a logger you set yourself, `nil` included, stays in charge. `--log-format` applies from the first line, and under `json` each line is one bare JSON object, ready for your log pipeline

- **Empty Environment Variables Count as Unset** – An empty `CLUSTER_ADDRESS=` pointed every client at an empty address, `BUSYBEE_WORKER_NAME=` named the worker `""`, an empty `BUSYBEE_CREDENTIAL_TYPE` logged an invalid-type warning, an empty credential variable such as `CAMUNDA_CLIENT_ID` stopped autodetection with `CannotDetectCredentials`, and `BUSYBEE_SKIP_RAILS=` skipped loading Rails. Each now behaves as though the variable were never set

- **A Configured Cluster Address Wins Over `CLUSTER_ADDRESS`** – With `CLUSTER_ADDRESS` set, a client built without arguments connected there even where `Busybee.cluster_address` or `busybee --cluster-address` pointed somewhere else. An app with `CLUSTER_ADDRESS` set and a different configured address now connects to the configured one, as the docs describe. With only one of the two set, nothing changes: `CLUSTER_ADDRESS` still applies when no address is configured, and `localhost:26500` when neither is
  - In a Rails app whose `config.x.busybee` sets credential keys but no address, `busybee --cluster-address` now reaches the credentials built from them. It used to be ignored there

### Breaking Changes:

- **Strict Output Validation Is On by Default** – A worker whose `perform` returns, or whose `complete!` passes, keys not declared as `output` raises `Busybee::UndeclaredOutput`, through the worker's `complete!` and `job.complete!` alike. Declare the keys, or add `strict_outputs false` to workers that intentionally return ad-hoc keys
- **`job.complete!` Checks Required Outputs From Inside a Worker** – Called from inside a worker, `job.complete!` now checks required outputs as the worker's own `complete!` does, raising `Busybee::MissingOutput` when one is missing. Pass every required output, or declare it `required: false`
- **`fail_job_on_error` Is Gone: Every Failure Is Reported** – Every exception that escapes `perform` is reported to the workflow engine. Switching that off left the job silently unresolved, and since a lease expiring doesn't spend a retry, a job that failed the same way every time looped indefinitely and never raised an incident for anyone to see
  - A worker still carrying the declaration raises `NoMethodError` when it loads, so you hear about it at boot rather than in production
  - To report a failure *your* way, rescue inside `perform` and resolve the job yourself: `fail!(e, retries: job.retries)` to come back without spending the budget, `throw_bpmn_error!` for an outcome your process model has a path for. Whatever your rescue doesn't catch is still reported for you
  - To take the worker process down on a class of errors, use `shutdown_on`; to reshape what reaches the engine across every worker, such as redacting sensitive text out of error messages, use a call hook
  - Busybee no longer warns that a job "will timeout and retry" when it had in fact already been completed
- **Duration Settings Renamed So Each One Names What It Sets** – A gem-level default is its per-worker setting with `default_` in front, and no name advertises a unit it shares with all the others:
  - `Busybee.grpc_retry_delay_ms` → `Busybee.grpc_retry_delay`
  - `Busybee.default_job_lock_timeout` → `Busybee.default_job_timeout`, matching the worker DSL's `job_timeout`
  - `Busybee.default_job_request_timeout` → `Busybee.default_polling_request_timeout`, matching `polling request_timeout:`
  - The worker DSL's `backoff` → `fail_job_backoff`, matching `Busybee.default_fail_job_backoff` and distinct from `backpressure_delay`, which is also a backoff and means something else entirely. The YAML key moves with it; `fail_job(backoff:)` and `job.fail!(backoff:)` are unchanged
- **Accepted Configuration Values Have One Home: `Busybee::Configure`** – The valid credential types, log formats and worker modes are `Busybee::Configure::VALID_CREDENTIAL_TYPES`, `VALID_LOG_FORMATS` and `VALID_WORKER_MODES`, and every entry is a Symbol
  - Code reading `Busybee::VALID_*`, `Busybee::RuntimeConfig::VALID_*` or `Busybee::Worker::Configuration::VALID_WORKER_MODES` raises `NameError`; read them from `Busybee::Configure` instead
  - Compare credential types and log formats as Symbols (`:json`, not `"json"`)
- **`busybee` Flags Give Way to Your App's Own Configuration** – `--cluster-address`, `--worker-name` and `--log-format` used to replace whatever your app set for the same setting, in `config.x.busybee`, an initializer, or a config file loaded ahead of the command. A flag now counts only where your app sets nothing, as with Sidekiq's flags, so your app has the last word, Rails or not
  - Busybee says so when a flag gives way: `Overriding --cluster-address "zeebe-a:26500" with config.x.busybee.cluster_address "zeebe-b:26500"`, or `with Busybee.cluster_address "zeebe-b:26500"` for a value set before the command ran
  - To let each deploy choose again, stop setting the value in your app, or set it there from the environment, such as `config.x.busybee.cluster_address = ENV["ZEEBE_ADDRESS"]`
- **Testing Helpers Go Only Where You Ask for Them** – `require "busybee/testing"` used to put every helper and matcher into every example in your suite, so a name like `execute_worker`, `build_test_job`, `complete_job` or `grpc_client` could silently shadow a helper of your own, or be shadowed by it, depending on include order. Now they reach only the specs that opt in: tag a group or example `:busybee`, or tag a whole directory from your spec helper with `define_derived_metadata`
  - To keep them everywhere, as before, add one line: `RSpec.configure { |config| config.include Busybee::Testing::Helpers }`
  - Until a spec opts in, a helper call raises `NameError`, and a `have_*` matcher fails with RSpec's own "expected … to respond to `has_received_variables?`"
  - The `without_busybee_hooks:` metadata keeps working in every spec, opted in or not
- **Workflow Tests Work Only Their Own Instance's Jobs** – Inside `with_process_instance`, `activate_job`, `activate_jobs` and `with_activated_job_instance` used to take whatever job of the type the engine offered first, and it offers the oldest: an instance an interrupted run left behind, or another test process on the same engine, handed your example its job, which then failed on someone else's variables or passed while its own instance never moved
  - A job of any other process instance is now handed back to the engine unworked, its retries untouched, and the helper waits on for its own
  - That includes the jobs of a call activity's child instance and of an instance your example starts by publishing a message: tag those examples `busybee_foreign_jobs: :accept`, or wrap the steps in `Busybee::Testing.accepting_foreign_jobs { }`
  - When `activate_job`, `with_activated_job_instance` or `activate_jobs(expected:)` comes up short, `NoJobsAvailable` names the jobs it handed back, and the tag
- **`activate_jobs` Activates Once, When You Call It, and Returns an Array** – It returned an Enumerator that asked the engine again on every enumeration, so a second read waited out its timeout and found nothing, and a result never read activated nothing. Now `.size`, `.first` and any number of reads see the same jobs
  - Code calling an Enumerator-only method on the result, such as `next` or `with_index`, needs `.each` first
  - `max_jobs:` takes only a positive Integer. Anything else raises `ArgumentError`, including 0, which used to return nothing without complaint
- **`assert_process_completed!` Raises `Busybee::Testing::ProcessStillRunning`** – When the process is still running it raised a plain `RuntimeError`, so `rescue RuntimeError` and `raise_error(RuntimeError)` no longer match it. The message hasn't changed, so a spec matching on the message keeps working
- **`have_activated` Is Gone: Check and Complete a Job in One Chain** – The matcher activated a job of the type you named and then kept it, so a spec could never complete that job and move the process on. Write each step as `activate_job("process-payment").expect_variables(order_id: "123").and_complete(payment_id: "pay-456")`: a Regexp or any RSpec matcher works as an expected value, and `expect { activate_job("x") }.not_to have_available_jobs` still asserts that nothing is waiting
- **`build_test_job` Hands Back a Real Job, and a Real Client With It** – The job is a genuine `ActivatedJob` protobuf rather than a fabricated stand-in, so it validates its own field types: `build_test_job(key: "abc")` raises where it used to be quietly accepted. Its client is real too (in-process, no network); pass `client:` to supply your own
- **`execute_worker` Hands Back the Job** – It returns the job (or the jobs, given `jobs:`) instead of `perform`'s return value, which is on `job.result`: `execute_worker(W, variables: {...}).result`
  - A job that fails doesn't re-raise into your example; its error is on `job.error`, so replace `expect { execute_worker(...) }.to raise_error(X)` with `expect(W).to fail_job(job).with_error(X)`
  - It runs your worker through a real worker lifecycle, so your worker, job and call hooks fire alongside the `perform` hooks. If a hook of yours writes somewhere a unit test would rather it didn't, subtract it with `without_busybee_hooks` or the `without_busybee_hooks:` metadata
- **Testing Helpers Keep Their Own Timings** – `activate_job` and `activate_jobs` waited for `Busybee.default_polling_request_timeout`, so a suite inherited whatever long-poll you had sized for production, and a spec looking for a job that was never coming sat through the whole minute. The harness now has its own timings, so no test environment has to override production settings to get sensible test behavior:
  - `Busybee::Testing::ACTIVATE_JOB_TIMEOUT_MS` (5 seconds), `ACTIVATE_JOB_LOCK_MS` (30 seconds) and `PUBLISH_MESSAGE_TTL_MS` (5 seconds)
  - Every one is overridable per call; pass `timeout:` where an example genuinely needs to wait longer
- **Testing Helper `publish_message` Parameters Renamed** – `variables:` is now `vars:` and `ttl_ms:` is now `ttl:`, matching `Client#publish_message`. `ttl:` accepts both an Integer (milliseconds) and an `ActiveSupport::Duration`
- **Testing Helper `zeebe_available?(timeout:)` Is Now `zeebe_available?(wait:)`** – `wait:` is the one parameter name in Busybee that means seconds, reserved for the test helpers that pause your own process. Everything else, including `activate_job(timeout:)` and `publish_message(ttl:)` alongside it, is milliseconds

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


