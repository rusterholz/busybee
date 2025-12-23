# frozen_string_literal: true

require "busybee/testing/rspec"

RSpec.describe "RSpec integration" do # rubocop:disable RSpec/DescribeClass
  it "includes helpers in example context" do # rubocop:disable RSpec/MultipleExpectations
    expect(self).to respond_to(:deploy_process)
    expect(self).to respond_to(:with_process_instance)
    expect(self).to respond_to(:activate_job)
    expect(self).to respond_to(:activate_jobs)
    expect(self).to respond_to(:publish_message)
    expect(self).to respond_to(:set_variables)
    expect(self).to respond_to(:assert_process_completed!)
  end

  it "loads have_received_variables matcher" do
    # Verify matcher is available by checking it responds in example context
    expect(self).to respond_to(:have_received_variables)
  end

  it "loads have_received_headers matcher" do
    expect(self).to respond_to(:have_received_headers)
  end

  it "loads have_activated matcher" do
    expect(self).to respond_to(:have_activated)
  end
end
