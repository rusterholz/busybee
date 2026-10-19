# frozen_string_literal: true

require "busybee/testing"

RSpec.describe "perform.call in a job's around hooks" do # rubocop:disable RSpec/DescribeClass
  let(:returning_worker) do
    Class.new(Busybee::Worker) do
      job_type "continued"
      strict_outputs false

      def perform = { total: 5 }
    end
  end

  let(:completing_worker) do
    Class.new(Busybee::Worker) do
      job_type "continued"
      strict_outputs false

      def perform
        complete!(total: 7)
        :ignored
      end
    end
  end

  around { |example| isolate_busybee_hooks { example.run } }

  %i[around_perform around_job_execution].each do |type|
    context "with an #{type} hook" do
      it "returns the job's result, frozen and with indifferent access" do
        returned = nil
        Busybee.public_send(type) { |_job, perform| returned = perform.call }

        execute_worker(returning_worker)
        expect(returned).to be_a(ActiveSupport::HashWithIndifferentAccess).and(be_frozen)
        expect(returned[:total]).to eq(5)
      end

      it "returns it to every hook in the chain, however the inner ones return" do
        returned = []
        %i[outer inner].each do |label|
          Busybee.public_send(type) do |_job, perform|
            returned << [label, perform.call]
            :middleware_value
          end
        end

        execute_worker(returning_worker)
        expect(returned).to eq([[:inner, { "total" => 5 }], [:outer, { "total" => 5 }]])
      end

      it "returns the vars a manual complete! sent, not perform's own return" do
        returned = nil
        Busybee.public_send(type) { |_job, perform| returned = perform.call }

        execute_worker(completing_worker)
        expect(returned).to eq("total" => 7)
      end
    end
  end
end
