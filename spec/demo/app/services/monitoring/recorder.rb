# frozen_string_literal: true

require "concurrent"

module Monitoring
  # Records busybee lifecycle into the Monitoring models — the demo's stand-in
  # for an observability sink (Datadog, etc.). Job activation/execution feed
  # Monitoring::JobRun; the four worker-lifecycle hooks feed WorkerProcess; every
  # call feeds EngineCall.
  #
  # Writes offload to a single background thread per process, so no hook waits
  # on the database: each hook snapshots its subject synchronously (a Job mutates
  # as it progresses, so we can't defer reading it) and posts the write. Every
  # row has exactly one writing process, so the writer also serializes each
  # row's read-compare-write. But a real observability sink is async,
  # out-of-order, and at-least-once — so the write must not trust arrival order.
  # Each observation carries its lifecycle
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
      # same slot in the bracket — without it a deploy leaves rows stuck at rank 0
      # forever, which is exactly the leak the pairing exists to prevent. Nothing
      # was attempted, so there are no durations and the status is still :ready;
      # a handback that failed to reach the engine is the worker's error, not the
      # job's, which is why it comes off worker_status.
      def record_handback(job)
        upsert(JobRun, activation(job),
               rank: 1,
               **job_columns(job),
               executed_at: Time.current,
               buffer_latency_ms: job.buffer_latency_ms,
               error_message: job.worker_status&.error_message)
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

      # Every resolved call becomes an EngineCall row, snapshotted here and
      # inserted on the writer; a resolution call also folds its outcome into
      # its JobRun.
      def record_call(call)
        row = EngineCall.row_for(call, seq: monotonic_seq)
        return unless row

        write("EngineCall #{row[:rpc]}") { EngineCall.insert_all([row]) }
        record_resolution(call)
      end

      # One background thread, unbounded queue: posts never block the runner, and
      # writes land in the order they were posted.
      def executor
        @executor ||= Concurrent::SingleThreadExecutor.new(fallback_policy: :discard)
      end

      # Drain the queue and stop the writer — registered at_exit (initializer).
      # Ruby's exit sequence runs at_exit handlers, then KILLS remaining threads,
      # then runs finalizers; a writer killed mid-write inside a native driver can
      # leave the connection's native lock held, and the finalizer that closes it
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
      # Fold its outcome and timing back in at execution rank: the (rank, seen_at)
      # guard makes either arrival order converge (status from the later
      # observation, other columns gap-filled from the earlier one). after_call
      # fires before the job marks itself resolved, so the call's own resolution
      # stamp is the resolution time.
      def record_resolution(call)
        job = call.job
        status = RESOLUTION_STATUSES[call.rpc.to_s]
        return unless status && job && call.succeeded?

        total_ms = ((call.resolved_at(:monotonic) - job.activated_at(:monotonic)) * 1000).round(1)
        upsert(JobRun, activation(job), rank: 1, status: status,
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

      # Capture the observation-order key NOW — in the hook, before the async post,
      # since write order is exactly what gets scrambled — then offload the write.
      def upsert(model, identity, rank:, **attributes)
        seen_at = monotonic_seq
        write("#{model.name} #{identity.values.join('/')}") { apply(model, identity, rank, seen_at, attributes) }
      end

      # Offload one write to the writer thread, in its own (sub)transaction so a
      # dropped write rolls back alone.
      def write(label, &)
        executor.post do
          Monitoring::Record.connection_pool.with_connection do
            Monitoring::Record.transaction(requires_new: true, &)
          end
        rescue StandardError => e
          Rails.logger.warn("[monitoring] dropped #{label}: #{e.message}")
        end
      end

      # Idempotent, out-of-order-safe apply. The ordering key is composite —
      # (lifecycle_rank, seen_at): rank is the primary semantic phase order, seen_at
      # only breaks ties within a rank (a long-running phase is observed many
      # times). A write at or behind the row's recorded position can still fill
      # gaps it uniquely owns, but never clobbers or regresses current state.
      #
      # The read-compare-write is atomic here only because a row's writes all come
      # from one process, whose single writer serializes them; the production twin
      # is one conditional UPSERT (... ON
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
