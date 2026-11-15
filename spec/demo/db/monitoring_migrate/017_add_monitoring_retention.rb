# frozen_string_literal: true

# Six hours of history, kept by TimescaleDB's own job scheduler: retention
# policies drop whole hypertable chunks, and a scheduled procedure deletes
# worker incarnations from the plain worker table.
class AddMonitoringRetention < ActiveRecord::Migration[7.0]
  def up
    %w[monitoring_job_runs monitoring_engine_calls].each do |table|
      execute "SELECT add_retention_policy('#{table}', drop_after => INTERVAL '6 hours', " \
              "schedule_interval => INTERVAL '10 minutes')"
    end

    # Stopped incarnations go after six hours untouched; one still marked
    # running (idle, or killed before its shutdown hooks) after a day.
    execute <<~SQL
      CREATE PROCEDURE monitoring_prune_worker_processes(job_id integer, config jsonb)
      LANGUAGE SQL AS $$
        DELETE FROM monitoring_worker_processes
        WHERE (status <> 'running' AND updated_at < (now() AT TIME ZONE 'UTC') - INTERVAL '6 hours')
           OR updated_at < (now() AT TIME ZONE 'UTC') - INTERVAL '1 day'
      $$
    SQL
    execute "SELECT add_job('monitoring_prune_worker_processes', INTERVAL '10 minutes')"
  end

  def down = raise ActiveRecord::IrreversibleMigration
end
