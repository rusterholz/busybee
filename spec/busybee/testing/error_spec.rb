# frozen_string_literal: true

require "busybee/error"
require "busybee/testing/error"

RSpec.describe Busybee::Testing::Error do
  it "is a StandardError, so a bare rescue catches it" do
    rescued = begin
      raise described_class, "test-time problem"
    rescue => e # rubocop:disable Style/RescueStandardError
      e
    end

    expect(rescued).to be_a(described_class)
  end

  [
    Busybee::Testing::NoJobsAvailable,
    Busybee::Testing::NoCurrentProcessInstance,
    Busybee::Testing::ProcessStillRunning
  ].each do |error_class|
    describe error_class.name do
      it "is rescued as a Busybee::Testing::Error" do
        expect { raise error_class, "test-time problem" }.to raise_error(described_class, "test-time problem")
      end

      it "goes past a rescue of Busybee::Error" do
        expect do
          raise error_class
        rescue Busybee::Error
          nil
        end.to raise_error(error_class)
      end
    end
  end

  it "goes past a rescue of Busybee::Error" do
    expect do
      raise described_class
    rescue Busybee::Error
      nil
    end.to raise_error(described_class)
  end

  describe "NoJobAvailable, the former name of NoJobsAvailable" do
    it "rescues a NoJobsAvailable" do
      rescued = begin
        raise Busybee::Testing::NoJobsAvailable, "nothing waiting"
      rescue Busybee::Testing::NoJobAvailable => e
        e
      end

      expect(rescued.class.name).to eq("Busybee::Testing::NoJobsAvailable")
    end

    it "reaches a raise_error naming the former name" do
      expect { raise Busybee::Testing::NoJobsAvailable }.to raise_error(Busybee::Testing::NoJobAvailable)
    end
  end
end
