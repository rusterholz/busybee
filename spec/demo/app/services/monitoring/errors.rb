# frozen_string_literal: true

module Monitoring
  # Where errors happen over the range: the calls that errored, by error class
  # and where they came from, and the worker stops that carried an error.
  class Errors
    CALL_KEYS = %i[error_class rpc job_type worker_class].freeze
    STOP_KEYS = %i[error_class worker_class reason].freeze

    def initialize(calls, workers, window)
      @calls = calls.within(window).where(status: "errored")
      @stops = workers.where(shutdown_at: window.from..window.to).where.not(error_class: nil)
      @window = window
    end

    # [{ error_class:, rpc:, job_type:, worker_class:, count:, last_at:, sample_message: }], most first.
    def calls
      aggregates = [Arel.sql("COUNT(*)"), Arel.sql("MAX(at)"), Arel.sql("MAX(error_message)")]
      rows = @calls.group(*CALL_KEYS).pluck(*CALL_KEYS, *aggregates).map do |*keys, count, last_at, message|
        CALL_KEYS.zip(keys).to_h.merge(count: count, last_at: last_at, sample_message: message)
      end
      rows.sort_by { |row| [-row[:count], row[:error_class].to_s] }
    end

    # Errored calls per minute in every bucket, zero where there were none.
    def calls_per_minute
      bucket = Arel.sql(@window.bucket_sql(:at))
      counts = @calls.group(bucket).count
      @window.buckets.index_with { |at| @window.per_minute(counts.fetch(at, 0), at) }
    end

    # [{ error_class:, worker_class:, reason:, count:, sample_message: }], most first.
    def worker_stops
      rows = @stops.group(*STOP_KEYS).pluck(*STOP_KEYS, Arel.sql("COUNT(*)"), Arel.sql("MAX(error_message)"))
      rows = rows.map do |*keys, count, message|
        STOP_KEYS.zip(keys).to_h.merge(count: count, sample_message: message)
      end
      rows.sort_by { |row| [-row[:count], row[:error_class].to_s] }
    end
  end
end
