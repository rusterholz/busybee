# frozen_string_literal: true

require_relative "../rails_helper"
require "rack/test"

# Every monitoring link and redirect is built from the query string, so none may
# carry url_for's own options (host, protocol, port) off the site.
RSpec.describe "Monitoring links" do # rubocop:disable RSpec/DescribeClass
  include Rack::Test::Methods

  def app = Rails.application

  let(:hostile) { "host=evil.example&protocol=javascript&port=6666&failed=1&worker_status=all" }

  before do
    %w[pick ship].each_with_index do |job_type, i|
      Monitoring::JobRun.create!(job_key: i, activated_at: Time.current, job_type: job_type, status: "complete")
    end
  end

  %w[/monitoring/workers /monitoring/workflows /monitoring/infrastructure].each do |page|
    it "keeps every link on #{page} on this site" do
      get "#{page}?job_type[]=pick&#{hostile}"

      expect(last_response.body).not_to include("evil.example", "javascript:", "6666")
    end
  end

  it "keeps the redirect for a complete job-type selection on this site" do
    get "/monitoring/workers?job_type[]=pick&job_type[]=ship&#{hostile}"

    expect(last_response.status).to eq(302)
    expect(last_response.headers["Location"]).to start_with("http://example.org/monitoring/workers")
    expect(last_response.headers["Location"]).not_to include("evil.example", "6666")
  end

  it "keeps the redirect from /monitoring on this site" do
    get "/monitoring?#{hostile}"

    expect(last_response.headers["Location"]).to start_with("http://example.org/monitoring/workers")
    expect(last_response.headers["Location"]).not_to include("evil.example", "6666")
  end
end
