# frozen_string_literal: true

module Monitoring
  # A lean per-(metric_name, tag-tuple) aggregate — count, min, max, and an
  # exponentially-weighted moving average + variance — folded in one value at a
  # time. No metrics library, no per-event rows: an engine call has no intrinsic
  # key, so it's aggregated, not recorded.
  #
  # Unlike the state carriers (JobRun / WorkerProcess), an aggregate can't be
  # "superseded" — it accumulates. So the concerns differ: it takes AT-LEAST-ONCE
  # semantics (a rare duplicate double-counts and slightly skews the average — the
  # honest trade every real metric sink makes, versus an event store that would
  # defeat the point). And because hooks fire on many worker threads at once, the
  # fold is a single atomic UPSERT with SQL-side decay — never a Ruby
  # read-modify-write, which would lose updates under contention.
  class CallMetric < Record
    self.table_name = "monitoring_call_metrics"

    # EWMA/EWMV decay: how strongly each new sample pulls the average. Higher is
    # more reactive, lower is smoother.
    ALPHA = 0.1

    # The incremental fold, applied atomically on conflict. Every right-hand side
    # reads the row's *current* values, so ewma and ewmv both see the old ewma
    # (ewmv needs it — it's the pre-update delta), and SET order is irrelevant.
    # `excluded` is the would-be-inserted row: its ewma is the new sample x, and
    # its minimum/maximum are x too.
    FOLD_SQL = <<~SQL.squish
      count = monitoring_call_metrics.count + 1,
      minimum = min(monitoring_call_metrics.minimum, excluded.minimum),
      maximum = max(monitoring_call_metrics.maximum, excluded.maximum),
      ewmv = (1 - #{ALPHA}) * (monitoring_call_metrics.ewmv +
             #{ALPHA} * (excluded.ewma - monitoring_call_metrics.ewma) *
                        (excluded.ewma - monitoring_call_metrics.ewma)),
      ewma = monitoring_call_metrics.ewma + #{ALPHA} * (excluded.ewma - monitoring_call_metrics.ewma)
    SQL

    class << self
      # Fold one sample into the (metric_name, tags) aggregate. Thread-safe: a
      # single atomic UPSERT, callable inline from any worker thread.
      def observe(metric_name, tags, value)
        upsert_all(
          [{ id: SecureRandom.uuid, metric_name: metric_name, tag_key: tag_key(tags),
             tags: tags, count: 1, minimum: value, maximum: value, ewma: value, ewmv: 0.0 }],
          unique_by: %i[metric_name tag_key],
          on_duplicate: Arel.sql(FOLD_SQL)
        )
      end

      # Canonical, order-independent key for a tag tuple (the unique-index half).
      def tag_key(tags) = JSON.generate(tags.transform_keys(&:to_s).sort.to_h)
    end

    def stddev = Math.sqrt(ewmv || 0.0)
  end
end
