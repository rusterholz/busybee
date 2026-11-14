# frozen_string_literal: true

require "concurrent"

module Monitoring
  # Records busybee lifecycle into the Monitoring models: the demo's stand-in
  # for an observability sink (Datadog, etc.). Job activation/execution feed
  # Monitoring::JobRun; the four worker-lifecycle hooks feed WorkerProcess; every
  # call feeds EngineCall.
  #
  # Writes offload to a single background thread per process, so no hook waits
  # on the database: each hook snapshots its subject synchronously (a Job mutates
  # as it progresses, so we can't defer reading it) and queues the write. Two
  # lanes: worker lifecycle rows, which the writer lands first, and telemetry
  # (job runs, calls, worker refreshes), which it lands in batches behind them
  # and which may be dropped at exit under a backlog. A real observability sink
  # is async, out-of-order, and at-least-once, so the write must not trust
  # arrival order. Each observation carries its lifecycle rank (a semantic phase
  # order) plus a monotonic seen_at (an intra-rank freshness tiebreaker, stamped
  # at observation time), and lands as one GuardedUpsert, which refuses any write
  # a superseding one has already overtaken. Best-effort: a failed write is
  # logged and dropped, never retried into the hot path.
  module Recorder
    # Lifecycle rank of each worker phase: the primary, semantic ordering the
    # guard advances through (running never supersedes shutdown, however it lands).
    WORKER_PHASES = { running: 0, stop_requested: 1, stopping: 2, shutdown: 3 }.freeze

    # The run outcome each resolution RPC implies (keyed by gRPC rpc name;
    # the BPMN-error RPC is throw_error on the wire, not throw_bpmn_error).
    RESOLUTION_STATUSES = { "complete_job" => "complete", "fail_job" => "failed",
                            "throw_error" => "error" }.freeze

    # A run returned to the engine unworked: busybee's own shutdown handback, or
    # a worker's that marks the job with job.context[:handed_back] before failing it.
    HANDED_BACK = "handed_back"

    BATCH_SIZE = 200

    class << self
      def record_activation(job)
        upsert(JobRun, activation(job),
               rank: 0,
               **job_columns(job),
               source: job.source&.to_s,
               buffer_size: job.worker_status&.current_buffer_size,
               buffered: job.buffered?)
      end

      def record_execution(job)
        upsert(JobRun, activation(job),
               rank: 1,
               **job_columns(job),
               executed_at: job.executed_at,
               resolved_at: job.resolved_at,
               total_duration_ms: job.total_duration_ms,
               perform_duration_ms: job.perform_duration_ms,
               execution_duration_ms: job.execution_duration_ms,
               buffer_latency_ms: job.buffer_latency_ms,
               error_message: job.error_message,
               error_code: job.error_code)
      end

      # The other way an activation closes: the worker was shutting down and handed
      # the job straight back unworked. Same rank as an execution because it is the
      # same slot in the bracket; without it a deploy leaves rows stuck at rank 0
      # forever, which is exactly the leak the pairing exists to prevent. Nothing
      # was attempted, so there are no durations; the job is still :ready, and the
      # run is handed_back (which also overtakes the handback's own fail_job,
      # folded just before it as "failed"). A handback that failed to reach the
      # engine is the worker's error, not the job's, which is why it comes off
      # worker_status.
      def record_handback(job)
        upsert(JobRun, activation(job),
               rank: 1,
               **job_columns(job),
               status: HANDED_BACK,
               executed_at: Time.current,
               buffer_latency_ms: job.buffer_latency_ms,
               error_message: job.worker_status&.error_message)
      end

      # Upsert a worker's lifecycle phase, keyed by its container identity
      # (worker_name is unique per boot, so each incarnation is its own row).
      # Lifecycle rows ride their own lane, never queued behind telemetry.
      def record_worker(status, worker)
        upsert(WorkerProcess, { worker_name: worker.worker_name, job_type: worker.job_type },
               rank: WORKER_PHASES.fetch(status), lane: :lifecycle, status: status.to_s, **worker_columns(worker))
      end

      # Refresh a running worker's counters and gauges: telemetry, like a call.
      def refresh_worker(worker)
        upsert(WorkerProcess, { worker_name: worker.worker_name, job_type: worker.job_type },
               rank: WORKER_PHASES[:running], status: "running", **worker_columns(worker))
      end

      # Every resolved call becomes an EngineCall row, snapshotted here and
      # inserted on the writer; a resolution call also folds its outcome into
      # its JobRun.
      def record_call(call)
        row = EngineCall.row_for(call, seq: monotonic_seq)
        return unless row

        write("EngineCall #{row[:rpc]}") { EngineCall.insert_all([row]) }
        record_resolution(call)
      end

      # One background thread: posts never block the runner, and each lane's
      # writes land in the order they were posted, a batch per transaction.
      def executor
        @executor ||= begin
          @lanes = nil
          Concurrent::SingleThreadExecutor.new(fallback_policy: :discard)
        end
      end

      # Kill the writer and discard everything queued: the executor and both lanes
      # start fresh on the next write. For specs; production ends in shutdown!.
      def reset!
        @executor&.kill
        @executor = @lanes = nil
      end

      # Drain the queue and stop the writer, registered at_exit (initializer).
      # Ruby's exit sequence runs at_exit handlers, then KILLS remaining threads,
      # then runs finalizers; a writer killed mid-write inside a native driver can
      # leave the connection's native lock held, and the finalizer that closes it
      # then deadlocks the process: immortal PID 1, restart policy never fires.
      # Draining here, before the kill step, removes that window; late posts fall
      # to the executor's :discard policy.
      def shutdown!(timeout: 10)
        writer = @executor
        return unless writer

        writer.shutdown
        return if writer.wait_for_termination(timeout)

        Rails.logger.warn("[monitoring] write queue did not drain by process exit")
      end

      # Block until the lifecycle rows queued so far have landed (or timeout, =>
      # false), however much telemetry is queued. Unlike shutdown!, leaves the
      # executor accepting: the on_worker_shutdown flush point, where sibling
      # runners still record.
      def flush_lifecycle(timeout: 5)
        latch = Concurrent::CountDownLatch.new(1)
        writer = executor
        lanes[:lifecycle] << [:signal, latch]
        writer.post { drain }
        latch.wait(timeout)
      end

      private

      # An async resolution (a worker thread calling complete!/fail! after perform
      # returned) lands after record_execution snapshotted the run still-ready, and
      # no job hook fires at resolution time: the RPC itself is the last signal.
      # Fold its outcome and timing back in at execution rank: the (rank, seen_at)
      # guard makes either arrival order converge (status from the later
      # observation, other columns gap-filled from the earlier one). after_call
      # fires before the job marks itself resolved, so the call's own resolution
      # stamp is the resolution time.
      def record_resolution(call)
        job = call.job
        status = RESOLUTION_STATUSES[call.rpc.to_s]
        return unless status && job && call.succeeded?

        status = HANDED_BACK if job.context[:handed_back]
        total_ms = ((call.resolved_at(:monotonic) - job.activated_at(:monotonic)) * 1000).round(1)
        upsert(JobRun, activation(job), rank: 1, status: status, job_type: job.job_type, # NOT NULL, even on conflict
                                        resolved_at: call.resolved_at, total_duration_ms: total_ms)
      end

      def activation(job) = { job_key: job.key, activated_at: job.activated_at }

      # What every job-run write carries: the job's type, workflow coordinates,
      # status and tags, and the process recording it.
      def job_columns(job)
        { job_type: job.job_type, bpmn_process_id: job.bpmn_process_id, element_id: job.element_id,
          process_instance_key: job.process_instance_key, worker_name: job.worker_name,
          status: job.status.to_s, tags: job.context_tags }
      end

      # Capture the observation-order key NOW, in the hook, before the async post
      # (write order is exactly what gets scrambled), then offload the write.
      def upsert(model, identity, rank:, lane: :telemetry, **attributes)
        seen_at = monotonic_seq
        write("#{model.name} #{identity.values.join('/')}", lane: lane) do
          GuardedUpsert.call(model, identity, rank: rank, seen_at: seen_at, attributes: attributes)
        end
      end

      # Queue one write for the writer thread. Each pass lands every queued
      # lifecycle write, then up to BATCH_SIZE telemetry writes, a transaction each.
      def write(label, lane: :telemetry, &work)
        writer = executor # first, since a new executor starts new lanes
        lanes.fetch(lane) << [label, work]
        writer.post { drain }
      end

      def lanes = @lanes ||= { lifecycle: Thread::Queue.new, telemetry: Thread::Queue.new }

      def drain
        land_batch(take(:lifecycle, Float::INFINITY))
        land_batch(take(:telemetry, BATCH_SIZE))
      end

      # The writer is each lane's only consumer, so everything counted is there to pop.
      def take(lane, limit)
        queue = lanes.fetch(lane)
        Array.new([queue.size, limit].min) { queue.pop }
      end

      # A flush_lifecycle signal in the batch fires once the writes ahead of it commit.
      def land_batch(batch)
        signals, writes = batch.partition { |label, _| label == :signal }
        if writes.any?
          Monitoring::Record.connection_pool.with_connection do
            Monitoring::Record.transaction(requires_new: true) { writes.each { |entry| entry.last.call } }
          rescue StandardError
            writes.each { |label, work| land(label, &work) }
          end
        end
        signals.each { |signal| signal.last.count_down }
      end

      # A failed batch's writes, replayed each in its own savepoint, so a bad
      # write is dropped alone. Every write is safe to replay: the batch rolled back.
      def land(label, &)
        Monitoring::Record.transaction(requires_new: true, &)
      rescue StandardError => e
        Rails.logger.warn("[monitoring] dropped #{label}: #{e.message}")
      end

      # A worker's descriptive columns: identity/outcome (scalarised for storage)
      # plus the high-cardinality gauges/counters/timestamps read uniformly off the
      # status snapshot, plus the recorder's own write backlog.
      def worker_columns(worker)
        gauges = %i[total_job_count failed_job_count backpressure_count
                    current_buffer_size peak_buffer_size started_at
                    stop_requested_at stopping_at shutdown_at].
                 index_with { |reader| worker.public_send(reader) }

        { worker_class: worker.worker_class.name,
          worker_mode: worker.worker_mode.to_s,
          reason: worker.reason&.to_s,
          error_class: worker.error_class&.name,
          error_message: worker.error_message,
          write_queue_depth: queue_depth,
          **gauges }
      end

      def monotonic_seq = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      # The recorder's own write backlog, sampled synchronously in the hook: a
      # "how live is this?" gauge persisted per worker.
      def queue_depth = lanes.values.sum(&:size)
    end
  end
end
