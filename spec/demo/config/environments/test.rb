# frozen_string_literal: true

Rails.application.configure do
  # A spec run shouldn't mutate version-controlled files. rails_helper's
  # prepare_all migrates the per-domain test databases; without this, a pending
  # migration would re-dump (and clobber the hand-kept) *_schema.rb on every run.
  # Schemas are maintained alongside their migrations by hand.
  config.active_record.dump_schema_after_migration = false
end
