# frozen_string_literal: true

module Monitoring
  # The dashboard's time range: how far back to look, and the bucket width its
  # charts use (sized to keep each chart at 30-72 points).
  class Window
    SPANS = { "15m" => [15.minutes, 30.seconds], "1h" => [1.hour, 1.minute], "6h" => [6.hours, 5.minutes] }.freeze
    KEYS = SPANS.keys.freeze
    DEFAULT = "1h"

    attr_reader :key, :from, :to, :bucket

    def initialize(key, now: Time.current)
      @key = SPANS.key?(key) ? key : DEFAULT
      span, @bucket = SPANS.fetch(@key)
      @to = now
      @from = now - span
    end

    def minutes = (to - from) / 60.0
    def per_minute(count) = count * 60.0 / bucket

    # SQL for the bucket holding a timestamp column (time_bucket aligns to the epoch).
    def bucket_sql(column) = "time_bucket(INTERVAL '#{bucket.to_i} seconds', #{column})"

    # Every bucket start the range touches, so a chart shows quiet buckets as zero.
    def buckets
      (floor(from).to_i..floor(to).to_i).step(bucket.to_i).map { |seconds| Time.zone.at(seconds) }
    end

    private

    def floor(time) = Time.zone.at(time.to_i - (time.to_i % bucket.to_i))
  end
end
