# frozen_string_literal: true

module Monitoring
  # One observation written as one INSERT ... ON CONFLICT DO UPDATE, atomic in
  # Postgres. An observation whose (lifecycle_rank, seen_at) is ahead of the
  # row's takes over every column it carries; one that is behind only fills the
  # columns the row has no value for yet.
  module GuardedUpsert
    module_function

    def call(model, identity, rank:, seen_at:, attributes:)
      row = { **identity, **attributes, lifecycle_rank: rank, seen_at: seen_at }
      row[:id] = SecureRandom.uuid if model.primary_key == "id"
      model.upsert_all([row], unique_by: identity.keys, record_timestamps: true,
                              on_duplicate: Arel.sql(set_clause(model, attributes.keys)))
    end

    def set_clause(model, columns)
      table = model.quoted_table_name
      ahead = "(EXCLUDED.lifecycle_rank, EXCLUDED.seen_at) > " \
              "(COALESCE(#{table}.lifecycle_rank, -1), COALESCE(#{table}.seen_at, '-Infinity'))"
      quoted = columns.map { |column| model.connection.quote_column_name(column) }
      fills = quoted.map { |column| "(#{table}.#{column} IS NULL AND EXCLUDED.#{column} IS NOT NULL)" }

      sets = quoted.map do |column|
        "#{column} = CASE WHEN #{ahead} THEN EXCLUDED.#{column} " \
          "ELSE COALESCE(#{table}.#{column}, EXCLUDED.#{column}) END"
      end
      sets += %w[lifecycle_rank seen_at].map do |column|
        "#{column} = CASE WHEN #{ahead} THEN EXCLUDED.#{column} ELSE #{table}.#{column} END"
      end
      sets << "updated_at = CASE WHEN #{[ahead, *fills].join(' OR ')} THEN EXCLUDED.updated_at " \
              "ELSE #{table}.updated_at END"
      sets.join(",\n")
    end
  end
end
