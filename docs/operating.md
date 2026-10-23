# Operating Busybee

This page is for whoever runs the `busybee` command in production, under Kubernetes or any other orchestrator, and has to answer for it when something goes wrong. It covers what the process logs, what its exit status means, how long it takes to stop, what to probe, and where to look when a worker goes quiet. For how to define and configure workers, see [Workers](workers.md).

The log lines on this page were captured from real runs.

## Table of Contents

- [What Busybee Logs](#what-busybee-logs)
- [Booting](#booting)
- [Exit Status](#exit-status)
- [Shutting Down](#shutting-down)
  - [Signals](#signals)
  - [Make Sure the Signal Reaches Busybee](#make-sure-the-signal-reaches-busybee)
  - [What a Stop Waits For](#what-a-stop-waits-for)
  - [Sizing the Grace Period](#sizing-the-grace-period)
  - [A Forced Stop](#a-forced-stop)
- [When the Gateway Goes Away](#when-the-gateway-goes-away)
- [Health Checks](#health-checks)
- [When a Worker Goes Quiet](#when-a-worker-goes-quiet)
- [One Worker Down, Whole Container Down](#one-worker-down-whole-container-down)
- [Retries, Incidents and Poison Pills](#retries-incidents-and-poison-pills)
- [Tagging Requests for Correlation](#tagging-requests-for-correlation)

## What Busybee Logs

The `busybee` command logs to stdout from its first line, at `info`, until your app's logger takes over (see [Configuration: `logger`](configuration.md#logger)). Every line starts with `[busybee]` and leads with what happened. Each worker logs its start and its stop, with the stop's [reason](hooks.md#stop-reasons), and each job logs how it ended: completed, failed, threw a BPMN error, or handed back unworked during a shutdown. A worker stopped by SIGTERM while it held jobs it hadn't started:

```
I, [2026-10-22T09:16:14.660520 #21385]  INFO -- : [busybee] Started SlowOrderWorker (hybrid, job type process-order)
I, [2026-10-22T09:16:17.703176 #21385]  INFO -- : [busybee] Completed process-order job #2251799813685340
I, [2026-10-22T09:16:19.133773 #21385]  INFO -- : [busybee] Stopping SlowOrderWorker (sigterm)
I, [2026-10-22T09:16:20.724763 #21385]  INFO -- : [busybee] Completed process-order job #2251799813685346
I, [2026-10-22T09:16:20.733606 #21385]  INFO -- : [busybee] Handed back process-order job #2251799813685352, SlowOrderWorker shutting down (sigterm)
I, [2026-10-22T09:16:20.740479 #21385]  INFO -- : [busybee] Handed back process-order job #2251799813685358, SlowOrderWorker shutting down (sigterm)
I, [2026-10-22T09:16:20.747377 #21385]  INFO -- : [busybee] Handed back process-order job #2251799813685364, SlowOrderWorker shutting down (sigterm)
I, [2026-10-22T09:16:20.747721 #21385]  INFO -- : [busybee] Stopped SlowOrderWorker (sigterm)
```

Each job's activation is logged too, at `debug`. To quiet the per-job lines, set your logger's level to `warn`.

With `--log-format json`, each line is one JSON object carrying the fields of the job or worker it concerns, so you can filter on `job_key`, `job_type` or `worker_class` instead of parsing messages:

```json
{"retries":2,"deadline":"2026-10-22T15:16:55.450Z","job_type":"job-type-a","bpmn_process_id":"multi-job-process","element_id":"ServiceTask_A","job_key":2251799813685331,"process_instance_key":2251799813685321,"source":"poll","worker_class":"BoomWorker","buffered":false,"status":"failed","error_class":"ArgumentError","error_message":"bad order payload","activated_at":"2026-10-22T15:15:55.466Z","execution_started_at":"2026-10-22T15:15:55.466Z","perform_started_at":"2026-10-22T15:15:55.466Z","perform_finished_at":"2026-10-22T15:15:55.466Z","resolved_at":"2026-10-22T15:15:55.476Z","error_location":"/.../workers.rb:12:in `perform'","message":"[busybee] Failed job-type-a job #2251799813685331, 2 retries left (ArgumentError: bad order payload)","level":"info","time":"2026-10-22T15:15:55.477Z"}
```

**When the process exits on an error, the error goes to stderr.** The log lines name the stop's reason, and Ruby prints the error with its backtrace on stderr. Collect both streams:

```
I, [2026-10-22T09:18:54.565562 #21845]  INFO -- : [busybee] Stopping OkWorker (gateway_error)
I, [2026-10-22T09:18:54.565677 #21845]  INFO -- : [busybee] Stopped OkWorker (gateway_error)
```

```
/.../lib/busybee/grpc/error.rb:27:in `wrap': GRPC call failed (failed to connect to all addresses; last error: UNKNOWN: ipv4:127.0.0.1:26599: Failed to connect to remote host: Connection refused) (Busybee::GRPC::Error)
```

## Booting

In a bundle that includes Rails, the command loads your app from `./config/environment.rb` before it starts any worker. Three outcomes:

- **No Rails in the bundle, or `BUSYBEE_SKIP_RAILS=1`:** Rails is skipped, silently.
- **Rails in the bundle, but no `config/environment.rb` where the command runs:** it says so and carries on without Rails. If you expected your app to load, check the working directory:

  ```
  I, [2026-10-23T09:09:29.264094 #92086]  INFO -- : [busybee] Continuing without Rails, no config/environment.rb in /private/tmp/ar-v0.4-dev-m22/norails
  ```

- **Your app fails to boot:** the command logs why, Ruby prints the error and its backtrace on stderr, and the process exits with status 1, so a broken deploy shows up as a failed container:

  ```
  E, [2026-10-23T09:09:30.274450 #92096] ERROR -- : [busybee] Failed to load Rails environment in /private/tmp/ar-v0.4-dev-m22/badapp; set BUSYBEE_SKIP_RAILS=1 if this is not a Rails app (KeyError: key not found: "DATABASE_URL")
  ```

  Once Rails has set up your app's logger, this line goes there instead of stdout. The stderr report arrives either way.

`--cluster-address`, `--worker-name` and `--log-format` take effect before your app boots, so a value your app configures for the same setting wins over the flag, and Busybee logs when that happens:

```
PLACEHOLDER: the Railtie's override line, to be copied from a real run
```

[Configuration Precedence](configuration.md#configuration-precedence) has the full order.

A worker that can't reach the gateway when it starts stops with reason `gateway_error`, and the process exits with status 1. Your restart policy retries it.

## Exit Status

| Status | When |
|--------|------|
| `0` | A graceful stop on `INT`, `TERM` or `QUIT`, or a worker whose job stream the engine closed cleanly (reason `gateway_closed`) |
| `1` | A worker stopped on an error: the gateway failed (`gateway_error`), the worker declared itself unhealthy (`unhealthy`), or anything else (`crash`). The error and its backtrace are on stderr |
| `1` | A second termination signal forced the exit (see [A Forced Stop](#a-forced-stop)) |
| `1` | A line beginning `Exiting process immediately` was logged: an error the process can't recover from, such as `NoMemoryError`, struck a thread that couldn't raise it |
| `1` | The command couldn't start: your app failed to boot, a worker class couldn't be found, or the flags or YAML were invalid |
| `137` | The orchestrator's SIGKILL ended the process (see [Sizing the Grace Period](#sizing-the-grace-period)) |

The reason in the `Stopping` and `Stopped` lines is the same one [`on_worker_shutdown`](hooks.md#stop-reasons) receives, so an alert built on either agrees with the other.

## Shutting Down

### Signals

`INT`, `TERM` and `QUIT` each begin a graceful stop: the worker stops taking jobs, lets the `perform` in progress finish, hands back every job it received but hadn't started, and exits. Any second one of them forces the exit. [Workers: Signal Handling](workers.md#signal-handling) describes both.

Busybee handles no other signal. A `HUP`, for example, ends the process as a crash: the worker logs a stop with reason `crash`, hands nothing back, and the jobs it held come back to the engine once their [`job_timeout`](workers.md#job_timeout) lapses.

### Make Sure the Signal Reaches Busybee

Kubernetes and Docker send SIGTERM to the container's main process. Start busybee with the exec form of your command, so that process is busybee itself:

```dockerfile
CMD ["bundle", "exec", "busybee", "--config", "config/busybee.yml"]
```

`bundle exec` replaces itself with the command it runs, so busybee receives the signal directly. A wrapper script should `exec` busybee for the same reason. With the shell form (`CMD bundle exec busybee ...`), a shell may be the main process instead, and if it doesn't pass the signal on, the grace period ends in SIGKILL with no graceful stop at all.

### What a Stop Waits For

A graceful stop waits for:

- **The `perform` in progress**, however long it takes.
- **A polling worker's open request for jobs**, up to its `request_timeout` (60 seconds by default). A polling worker asks the gateway for jobs and waits for an answer, and a stop doesn't cut that wait short.
- **Your [teardown hooks](hooks.md#worker-hooks)** (`on_worker_stop_requested`, `on_worker_stopping`, `on_worker_shutdown`). See [Keep Hook Bodies Fast](hooks.md#keep-hook-bodies-fast).
- **A streaming or hybrid worker's job stream reader**, up to [`shutdown_wait_timeout`](configuration.md#shutdown_wait_timeout) (5 seconds by default).
- **Handing back each job not yet started**, one call to the engine per job. These calls have no deadline of their own, so a gateway slow to answer lengthens the stop.

There is no overall shutdown deadline. `shutdown_wait_timeout` bounds only how long a stopping worker waits on its other threads: its stream reader, or an `on_worker_stop_requested` hook still running on the thread that handled the signal.

### Sizing the Grace Period

Set your orchestrator's grace period (`terminationGracePeriodSeconds` in Kubernetes, 30 seconds unless you set it) to cover your longest `perform`, plus a few seconds for handbacks and teardown hooks.

If the orchestrator's SIGKILL arrives first, no job is lost. Every job the worker still held comes back to the engine once its `job_timeout` lapses, and another worker picks it up. What you pay is latency, and the job runs again from the start, so keep `perform` safe to repeat.

A polling worker at the default `request_timeout` can take up to 60 seconds to stop. Set its `request_timeout` below your grace period, or use hybrid mode, the default, which doesn't wait on an open request when it stops:

```yaml
# config/busybee.yml
worker_mode: polling
request_timeout: 20000  # 20 seconds, inside a 30-second grace period
workers:
  - ShipOrderWorker
```

### A Forced Stop

A second termination signal forces the exit: the process exits with status 1 within `shutdown_wait_timeout`, hands nothing back, and may skip your teardown hooks. Every job it held comes back once its `job_timeout` lapses. A streaming or hybrid worker logs how many jobs it was holding in its buffer:

```
I, [2026-10-22T09:20:49.959278 #22170]  INFO -- : [busybee] Stopping SlowOrderWorker (sigterm)
W, [2026-10-22T09:20:50.269982 #22170]  WARN -- : [busybee] Discarding 2 buffered job(s) on kill! of SlowOrderWorker
```

Jobs a worker had fetched by polling, outside the buffer, go back unannounced.

## When the Gateway Goes Away

At startup, a gateway busybee can't reach stops the worker with `gateway_error`, and the process exits with status 1.

While running, a worker that loses the gateway stops the same way, and your orchestrator's restart is the reconnect. **A gateway restart restarts your workers:**

```
I, [2026-10-23T09:12:35.364819 #92723]  INFO -- : [busybee] Started OkWorker (hybrid, job type process-order)
I, [2026-10-23T09:12:49.189621 #92723]  INFO -- : [busybee] Stopping OkWorker (gateway_error)
I, [2026-10-23T09:12:49.190382 #92723]  INFO -- : [busybee] Stopped OkWorker (gateway_error)
```

```
/.../lib/busybee/grpc/error.rb:27:in `wrap': Job stream failed (Stream removed (Socket closed (GOAWAY received; Error code: 0; Debug Text: app_requested))) (Busybee::GRPC::Error)
```

A gateway under load answers with `RESOURCE_EXHAUSTED` instead. A polling worker, and a hybrid worker while it polls for jobs that were waiting before it started, backs off for [`backpressure_delay`](workers.md#backpressure) and asks again, without stopping. The statuses that mean "back off" are [`backpressure_statuses`](configuration.md#backpressure_statuses), and only those requests consult it. A job stream doesn't: a streaming or hybrid worker whose stream fails stops, whatever the status.

## Health Checks

**Liveness:** the process exits on anything fatal it detects, so your restart policy does the rest. The one failure it can't see is a process that hangs on its way out, which [Hooks and Threads](hooks.md#the-failure-mode) describes.

**Don't probe the gateway for liveness.** A probe that fails whenever the gateway is unreachable restarts every worker at once on the first gateway hiccup, and a worker that loses the gateway already stops by itself.

**Not available yet:** busybee has no readiness signal, and nothing detects a `perform` that never returns. Such a job goes back to the engine once its `job_timeout` lapses, but the worker stays busy with it, and since a worker runs its jobs one at a time, that job type gets no more work from that worker.

## When a Worker Goes Quiet

| What you see | What to check |
|--------------|---------------|
| `Started`, then nothing, on a streaming worker | A job stream delivers only jobs that become available after it opens, so jobs that were already waiting never reach it. Use hybrid mode, the default, which also polls for them. See [Workers: Streaming](workers.md#streaming) |
| `Started`, then nothing, on any worker | The `Started` line names the job type the worker asks for: compare it with the task type in your BPMN |
| Nothing for about a minute after a crash or a forced stop | The jobs the old process held are still locked to it. They come back once their `job_timeout` lapses |
| A job's last line is its `Activated` line | Its `perform` hasn't returned. `Activated` lines are logged at `debug`, so lower your [logger's](configuration.md#logger) level to see them |
| Jobs piling up in the engine while a streaming worker idles | A stream the gateway judged too slow misses new jobs. See [Workers: Buffer Throttle](workers.md#buffer-throttle) |
| Jobs waiting in the engine, and a polling or hybrid worker logging nothing | It may be backing off from `RESOURCE_EXHAUSTED`, which isn't logged. `backpressure_count`, on the worker status your [hooks](hooks.md#reading-workerstatus) receive, counts each backoff |

## One Worker Down, Whole Container Down

When several workers run in one process, the process has one health. If any worker stops, for any reason, the rest stop with it and the process exits, so your orchestrator replaces the container instead of leaving one job type unworked while the container looks healthy:

```
I, [2026-10-23T09:11:18.434365 #92579]  INFO -- : [busybee] Stopping UnhealthyWorker (unhealthy)
I, [2026-10-23T09:11:18.444358 #92579]  INFO -- : [busybee] Handed back job-type-a job #2251799813685323, UnhealthyWorker shutting down (unhealthy)
I, [2026-10-23T09:11:18.444740 #92579]  INFO -- : [busybee] Stopped UnhealthyWorker (unhealthy)
E, [2026-10-23T09:11:18.444831 #92579] ERROR -- : [busybee] Stopping all workers after UnhealthyWorker failed (Busybee::Worker::Shutdown: Shutting down worker MacBookPro.localdomain due to ConnectionLost in UnhealthyWorker: "database went away")
I, [2026-10-23T09:11:18.444925 #92579]  INFO -- : [busybee] Stopping OkWorker (unhealthy)
I, [2026-10-23T09:11:18.445387 #92579]  INFO -- : [busybee] Stopped OkWorker (unhealthy)
```

[Workers: When One Worker Fails](workers.md#when-one-worker-fails) covers how hard each kind of failure stops the others.

## Retries, Incidents and Poison Pills

**A job's retries are spent only by failures the engine hears about.** Each failure busybee reports, whether `perform` raised or your code called `fail!`, spends one retry, unless your `fail!` passes `retries:` itself, and the line says how many are left. When none are left, the engine raises an incident, which you see in Operate.

**A failure the engine never hears about spends nothing.** When the report itself can't reach the engine, or the process dies mid-job, the job comes back once its `job_timeout` lapses, with its retries untouched. So a network outage across many jobs leaves their retries intact, while isolated hiccups spend them one at a time.

**A job handed back during a graceful stop keeps its retries**: it was never attempted. The job whose error matched [`shutdown_on`](workers.md#shutdown-handling) is the exception: it is reported as failed first, and spends a retry.

**A poison pill crash-loops without an incident.** An error outside `StandardError` raised by `perform`, such as a `NotImplementedError`, a `LoadError` or a `SystemStackError`, is never reported as the job's failure. The worker stops with reason `crash`, the process exits with status 1, and the job comes back once its `job_timeout` lapses, retries untouched:

```
I, [2026-10-23T09:15:55.064363 #93346]  INFO -- : [busybee] Started InvoiceWorker (hybrid, job type job-type-a)
I, [2026-10-23T09:15:55.115819 #93346]  INFO -- : [busybee] Stopping InvoiceWorker (crash)
I, [2026-10-23T09:15:55.116084 #93346]  INFO -- : [busybee] Stopped InvoiceWorker (crash)
```

```
/.../workers.rb:42:in `generate_invoice': invoices for this region (NotImplementedError)
```

If the error happens every time, every worker that takes the job crashes the same way, and the engine never raises an incident. The signs are restarts at roughly `job_timeout` intervals with the same backtrace on stderr each time. Until you can deploy the fix, rescue the error in `perform` and report it, so the job spends its retries and ends in an incident like any other failure:

```ruby
def perform
  generate_invoice
rescue NotImplementedError => e
  fail!(e)
end
```

```
I, [2026-10-23T09:16:11.559061 #93441]  INFO -- : [busybee] Failed job-type-a job #2251799813685355, 2 retries left (NotImplementedError: invoices for this region)
```

## Tagging Requests for Correlation

When a support ticket names an order and you need the process instance that handled it, it helps if the instance carries an id you already know. A call hook can add your own correlation id to every process instance your app starts, without touching any call site: see [Hooks: Changing the Request Before It's Sent](hooks.md#changing-the-request-before-its-sent).
