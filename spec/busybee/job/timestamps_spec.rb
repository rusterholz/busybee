# frozen_string_literal: true

require "busybee/job/timestamps"

RSpec.describe Busybee::Job::Timestamps do
  subject(:timestamps) { described_class.new }

  describe "#context_tags" do
    it "is always empty (timestamps aren't low-card labels)" do
      timestamps.stamp!(:activated_at)
      expect(timestamps.context_tags).to eq({})
    end
  end

  describe "#logging_context" do
    it "is empty before any stamping" do
      expect(timestamps.logging_context).to eq({})
    end

    it "returns the UTC hash of stamped values" do
      timestamps.stamp!(:activated_at)
      timestamps.stamp!(:executed_at)

      expect(timestamps.logging_context.keys).to contain_exactly(:activated_at, :executed_at)
      expect(timestamps.logging_context[:activated_at]).to be_a(Time)
      expect(timestamps.logging_context[:executed_at]).to be_a(Time)
    end

    it "omits timestamps that haven't been stamped" do
      timestamps.stamp!(:resolved_at)

      expect(timestamps.logging_context.keys).to eq([:resolved_at])
    end
  end

  describe "computed durations" do
    {
      perform_duration_ms: %i[perform_started_at perform_finished_at],
      resolution_duration_ms: %i[execution_started_at resolved_at],
      execution_duration_ms: %i[execution_started_at executed_at],
      buffer_latency_ms: %i[activated_at execution_started_at],
      total_duration_ms: %i[activated_at resolved_at],
      post_resolution_ms: %i[resolved_at executed_at],
      setup_duration_ms: %i[execution_started_at perform_started_at]
    }.each do |duration_method, (from, to)|
      describe "##{duration_method}" do
        it "is a positive Float when both #{from} and #{to} are stamped" do
          timestamps.stamp!(from)
          sleep 0.001
          timestamps.stamp!(to)

          expect(timestamps.public_send(duration_method)).to be_a(Float)
          expect(timestamps.public_send(duration_method)).to be > 0
        end

        it "is nil when #{from} is missing" do
          timestamps.stamp!(to)
          expect(timestamps.public_send(duration_method)).to be_nil
        end

        it "is nil when #{to} is missing" do
          timestamps.stamp!(from)
          expect(timestamps.public_send(duration_method)).to be_nil
        end
      end
    end
  end
end
