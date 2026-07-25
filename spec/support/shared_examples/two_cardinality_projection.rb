# frozen_string_literal: true

# The two-cardinality observability contract, pinned wherever it's implemented:
# context_tags (low-cardinality, metric labels) must project a subset of
# logging_context (high-cardinality, log fields) — same keys, same values.
# Host groups provide a reasonably-populated `projectable` (empty projections
# pass vacuously; populated ones prove the merge chains stay aligned).
RSpec.shared_examples "a two-cardinality projection" do
  it "projects logging_context as a value-agreeing superset of context_tags" do
    tags = projectable.context_tags
    logging = projectable.logging_context

    aggregate_failures do
      expect(tags.keys - logging.keys).to eq([]), "context_tags keys missing from logging_context"
      tags.each { |key, value| expect(logging[key]).to eq(value), "logging_context[#{key.inspect}] diverges" }
    end
  end
end
