# frozen_string_literal: true

require_relative "../../rails_helper"

# Retention runs inside TimescaleDB on its own schedule, so these read what the
# migrations registered and call the worker-table procedure directly.
RSpec.describe "Monitoring retention" do # rubocop:disable RSpec/DescribeClass
  def connection = Monitoring::Record.connection

  def jobs(proc_name)
    connection.select_rows(<<~SQL)
      SELECT hypertable_name, config->>'drop_after', schedule_interval::text
      FROM timescaledb_information.jobs WHERE proc_name = '#{proc_name}' ORDER BY hypertable_name
    SQL
  end

  it "drops job runs and engine calls after six hours" do
    expect(jobs("policy_retention")).to eq([%w[monitoring_engine_calls PT6H PT10M],
                                            %w[monitoring_job_runs PT6H PT10M]])
  end

  describe "the worker-table sweep" do
    def worker!(name, status, touched_at)
      Monitoring::WorkerProcess.create!(worker_name: name, job_type: "t", status: status).
        tap { |w| w.update_column(:updated_at, touched_at) }
    end

    it "is scheduled every ten minutes" do
      expect(jobs("monitoring_prune_worker_processes")).to eq([[nil, nil, "PT10M"]])
    end

    it "deletes stopped incarnations after six hours and running ones after a day" do
      worker!("stopped-old", "shutdown", 7.hours.ago)
      worker!("stopped-recent", "shutdown", 5.hours.ago)
      worker!("running-quiet", "running", 7.hours.ago)
      worker!("running-gone", "running", 25.hours.ago)

      connection.execute("CALL monitoring_prune_worker_processes(0, NULL)")

      expect(Monitoring::WorkerProcess.pluck(:worker_name)).to contain_exactly("stopped-recent", "running-quiet")
    end
  end
end
