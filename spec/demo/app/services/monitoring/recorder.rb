# frozen_string_literal: true

require "concurrent"

module Monitoring
  # Records busybee lifecycle into the Monitoring models — the demo's stand-in
  # for an observability sink (Datadog, etc.). Job activation/execution feed
  # Monitoring::JobRun; the four worker-lifecycle hooks feed WorkerProcess.
  #
  # Writes offload to a single background thread: each hook snapshots its subject
  # synchronously (a Job mutates as it progresses, so we can't defer reading it)
  # and posts the write. One writer matches SQLite's single-writer model. But a
  # real observability sink is async, out-of-order, and at-least-once — so the
  # write must not trust arrival order. Each observation carries its lifecycle
  # rank (a semantic phase order) plus a monotonic seen_at (an intra-rank
  # freshness tiebreaker, stamped at observation time); #apply rejects any write a
  # superseding one has already overtaken. Best-effort: a failed write is logged
  # and dropped, never retried into the hot path.
  module Recorder
    # Lifecycle rank of each worker phase — the primary, semantic ordering the
    # guard advances through (running never supersedes shutdown, however it lands).
    WORKER_PHASES = { running: 0, stop_requested: 1, stopping: 2, shutdown: 3 }.freeze

    # The run outcome each resolution RPC implies (keyed by gRPC rpc name —
    # the BPMN-error RPC is throw_error on the wire, not throw_bpmn_error).
    RESOLUTION_STATUSES = { "complete_job" => "complete", "fail_job" => "failed",
                            "throw_error" => "error" }.freeze

    class << self
      def record_activation(job)
        upsert(JobRun, { job_key: job.key },
               rank: 0,
               job_type: job.job_type,
               bpmn_process_id: job.bpmn_process_id,
               status: job.status.to_s,
               source: job.source&.to_s,
               buffer_size: job.worker_status&.current_buffer_size,
               buffered: job.buffered?,
               activated_at: job.activated_at,
               tags: job.context_tags)
      end

      def record_execution(job)
        upsert(JobRun, { job_key: job.key },
               rank: 1,
               job_type: job.job_type,
               bpmn_process_id: job.bpmn_process_id,
               status: job.status.to_s,
               executed_at: job.executed_at,
               total_duration_ms: job.total_duration_ms,
               perform_duration_ms: job.perform_duration_ms,
               execution_duration_ms: job.execution_duration_ms,
               buffer_latency_ms: job.buffer_latency_ms,
               error_message: job.error_message,
               error_code: job.error_code,
               tags: job.context_tags)
      end

      # Upsert a worker's current lifecycle phase, keyed by its container identity
      # (worker_name is unique per boot, so each incarnation is its own row).
      def record_worker(status, worker)
        upsert(WorkerProcess,
               { worker_name: worker.worker_name, job_type: worker.job_type },
               rank: WORKER_PHASES.fetch(status),
               status: status.to_s,
               **worker_columns(worker))
      end

      # Fold a resolved call two ways — the call stream projected across both
      # cardinalities. Low-card: its duration into the engine_call aggregate under
      # its context_tags. High-card: its logging_context as an EngineCall row, but
      # only for perform-phase calls (EngineCall.record no-ops without a job_key),
      # so the per-job log stays bounded. Neither is offloaded — both are atomic
      # single-statement writes, safe (and cheaper) inline on the worker thread.
      # (The resolution fold is the exception: a guarded upsert, so it rides the
      # executor like the other lifecycle writes.)
      def record_call(call)
        return if call.network_ms.nil?

        CallMetric.observe("engine_call", call.context_tags, call.network_ms)
        EngineCall.record(call, seq: monotonic_seq)
        record_resolution(call)
      end

      # One background thread, unbounded queue: posts never block the runner, and
      # writes serialize (matching SQLite) in the order they were posted.
      def executor
        @executor ||= Concurrent::SingleThreadExecutor.new(fallback_policy: :discard)
      end

      # Drain the queue and stop the writer — registered at_exit (initializer).
      # Ruby's exit sequence runs at_exit handlers, then KILLS remaining threads,
      # then runs finalizers; a writer killed mid-SQLite-write leaves the
      # connection's native mutex locked, and the finalizer that closes the DB
      # then deadlocks the process — immortal PID 1, restart policy never fires.
      # Draining here, before the kill step, removes that window; late posts fall
      # to the executor's :discard policy.
      def shutdown!(timeout: 10)
        writer = @executor
        return unless writer

        writer.shutdown
        return if writer.wait_for_termination(timeout)

        Rails.logger.warn("[monitoring] write queue did not drain by process exit")
      end

      # Block until everything queued so far has landed (or timeout, => false).
      # Unlike shutdown!, leaves the executor accepting — the mid-run flush point
      # (the on_worker_shutdown hook) where sibling runners still record.
      def flush(timeout: 5)
        latch = Concurrent::CountDownLatch.new(1)
        executor.post { latch.count_down }
        latch.wait(timeout)
      end

      private

      # An async resolution (a worker thread calling complete!/fail! after perform
      # returned) lands after record_execution snapshotted the run still-ready, and
      # no job hook fires at resolution time — the RPC itself is the last signal.
      # Fold its outcome back in at execution rank: the (rank, seen_at) guard makes
      # either arrival order converge (status from the later observation, timing
      # columns gap-filled from the earlier one).
      def record_resolution(call)
        ctx = call.logging_context
        status = RESOLUTION_STATUSES[ctx[:rpc].to_s]
        return unless status && ctx[:job_key] && ctx[:status].to_s == "succeeded"

        upsert(JobRun, { job_key: ctx[:job_key] }, rank: 1, status: status)
      end

      # Capture the observation-order key NOW — in the hook, before the async post,
      # since write order is exactly what gets scrambled — then offload the write.
      def upsert(model, identity, rank:, **attributes)
        seen_at = monotonic_seq
        executor.post do
          Monitoring::Record.connection_pool.with_connection do
            apply(model, identity, rank, seen_at, attributes)
          end
        rescue StandardError => e
          Rails.logger.warn("[monitoring] dropped #{model.name} #{identity.values.join('/')}: #{e.message}")
        end
      end

      # Idempotent, out-of-order-safe apply. The ordering key is composite —
      # (lifecycle_rank, seen_at): rank is the primary semantic phase order, seen_at
      # only breaks ties within a rank (a long-running phase is observed many
      # times). A write at or behind the row's recorded position can still fill
      # gaps it uniquely owns, but never clobbers or regresses current state.
      #
      # The read-compare-write is atomic here only because the single writer
      # serializes it; the production twin is one conditional UPSERT (... ON
      # CONFLICT DO UPDATE ... WHERE (excluded.lifecycle_rank, excluded.seen_at) >
      # (<table>.lifecycle_rank, <table>.seen_at)).
      def apply(model, identity, rank, seen_at, attributes)
        row = model.find_or_initialize_by(identity)
        incoming = [rank, seen_at]
        recorded = [row.lifecycle_rank || -1, row.seen_at || -Float::INFINITY]
        if (incoming <=> recorded).positive?
          row.update!(attributes.merge(lifecycle_rank: rank, seen_at: seen_at))
        else
          gaps = attributes.select { |key, _| row[key].nil? }
          row.update!(gaps) if gaps.any?
        end
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

      # The recorder's own write backlog, sampled synchronously in the hook — a
      # "how live is this?" gauge persisted per worker. An immediate executor
      # (tests) doesn't queue, so it has no backlog.
      def queue_depth = executor.respond_to?(:queue_length) ? executor.queue_length : 0
    end
  end
end
