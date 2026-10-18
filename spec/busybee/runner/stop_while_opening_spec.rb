# frozen_string_literal: true

# A stop that lands while a streaming worker is still opening its job stream,
# before it has a stream to close, with a real client. The job type is idle:
# the gateway holds the stream open and sends nothing.
RSpec.describe "a stop while the job stream is opening", :gateway do # rubocop:disable RSpec/DescribeClass
  let(:stream_gate) { Queue.new }
  let(:worker_class) do
    Class.new(Busybee::Worker) do
      job_type "stop_while_opening"
      worker_mode :streaming

      def perform = {}
    end
  end

  let(:runner) { Busybee::Runner::Streaming.new(worker_class, runtime_config: runtime_config, client: gateway.client) }
  let(:expected_reason) { :sigterm }

  around { |example| isolate_busybee_hooks { example.run } }

  before do
    gate = stream_gate
    gateway.on(:stream_activated_jobs) { Enumerator.new { |_| gate.pop } }
    interrupt = -> { interrupt_opening }
    allow(gateway.client).to receive(:open_job_stream).and_wrap_original do |open, *args, **options|
      open.call(*args, **options).tap { interrupt.call }
    end
  end

  after { stream_gate.close }

  def interrupt_opening = runner.stop!(reason: :sigterm)

  shared_examples "a stop that finishes cleanly" do
    it "closes the stream it opened and stops, reporting no error" do
      raised = :unset
      status = shutdown_status_from { raised = run_to_completion(seconds: 3) }

      aggregate_failures do
        expect(raised).to be_nil
        expect([status&.reason, status&.error]).to eq([expected_reason, nil])
      end
    end
  end

  describe "on an inline streaming worker" do
    let(:runtime_config) { Busybee::RuntimeConfig.new(buffer: false).resolve_for(worker_class) }

    it_behaves_like "a stop that finishes cleanly"
  end

  describe "on a buffered streaming worker" do
    let(:runtime_config) { Busybee::RuntimeConfig.new.resolve_for(worker_class) }

    it_behaves_like "a stop that finishes cleanly"
  end

  # Instead of this worker stopping, another worker in the process is killed,
  # which tells every worker to exit immediately, naming the kill.
  describe "when the process is told to exit immediately instead" do
    let(:runtime_config) { Busybee::RuntimeConfig.new(buffer: false).resolve_for(worker_class) }
    let(:expected_reason) { :kill }
    let(:sibling) do
      Busybee::Runner::Polling.new(worker_class, runtime_config: runtime_config, client: gateway.client)
    end

    def interrupt_opening = sibling.kill!

    it_behaves_like "a stop that finishes cleanly"
  end

  # The stop lands once the worker holds its stream, before it reads from it:
  # the stop closes a stream the worker has yet to read.
  describe "just after the worker takes the stream" do
    before do
      allow(gateway.client).to receive(:open_job_stream).and_call_original
      stopping = runner
      runner.singleton_class.prepend(Module.new do
        %i[run_inline run_with_buffer].each do |reader|
          define_method(reader) do
            stopping.stop!(reason: :sigterm)
            super()
          end
        end
        private :run_inline, :run_with_buffer
      end)
    end

    describe "on an inline streaming worker" do
      let(:runtime_config) { Busybee::RuntimeConfig.new(buffer: false).resolve_for(worker_class) }

      it_behaves_like "a stop that finishes cleanly"
    end

    describe "on a buffered streaming worker" do
      let(:runtime_config) { Busybee::RuntimeConfig.new.resolve_for(worker_class) }

      it_behaves_like "a stop that finishes cleanly"
    end
  end
end
