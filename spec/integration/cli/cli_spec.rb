# frozen_string_literal: true

require "base64"
require "fileutils"
require "tempfile"

RSpec.describe "CLI", :integration do
  let(:harness) { File.expand_path("test_harness.rb", __dir__) }
  let(:job_bpmn_path) { File.expand_path("../../fixtures/job_process.bpmn", __dir__) }
  let(:multi_job_bpmn_path) { File.expand_path("../../fixtures/multi_job_process.bpmn", __dir__) }
  let(:client) { local_busybee_client }
  let(:spawned_handles) { [] }
  let(:signal_file) { Tempfile.new("busybee_cli_test") }
  let(:signal_path) do
    path = signal_file.path
    signal_file.close
    File.write(path, "")
    path
  end

  around do |example|
    original = Busybee.credential_type
    Busybee.credential_type = :insecure
    example.run
    Busybee.credential_type = original
  end

  after do
    cleanup_spawned_processes!
    signal_file.unlink
  end

  # --- Subprocess helpers ---

  def spawn_cli(*args, env: {})
    base_env = {
      "BUSYBEE_SKIP_RAILS" => "1",
      "BUSYBEE_TEST_SIGNAL_FILE" => signal_path
    }
    cmd = ["bundle", "exec", "ruby", harness, *args]

    out_rd, out_wr = IO.pipe
    err_rd, err_wr = IO.pipe
    pid = Process.spawn(base_env.merge(env), *cmd, out: out_wr, err: err_wr, chdir: project_root)
    out_wr.close
    err_wr.close

    handle = { pid: pid, stdout: out_rd, stderr: err_rd }
    spawned_handles << handle
    handle
  end

  def stop_cli(handle, signal: "TERM", timeout: 10)
    Process.kill(signal, handle[:pid])
    wait_for_exit(handle, timeout: timeout)
  end

  def wait_for_exit(handle, timeout: 10)
    deadline = Time.now + timeout
    loop do
      result = Process.waitpid2(handle[:pid], Process::WNOHANG)
      if result
        handle[:exited] = true
        return result[1]
      end
      raise "CLI process #{handle[:pid]} did not exit within #{timeout}s" if Time.now > deadline

      sleep 0.1
    end
  end

  # Read all remaining output after a process has exited.
  # Uses blocking reads — safe because the write ends are closed.
  def drain_output(handle)
    { stdout: handle[:stdout].read, stderr: handle[:stderr].read }
  end

  def signal_file_lines
    File.readlines(signal_path).map(&:strip).reject(&:empty?)
  end

  def cleanup_spawned_processes!
    spawned_handles.each { |handle| terminate_handle(handle) }
    spawned_handles.clear
  end

  def terminate_handle(handle) # rubocop:disable Metrics/AbcSize,Metrics/CyclomaticComplexity,Metrics/PerceivedComplexity
    unless handle[:exited]
      Process.kill("TERM", handle[:pid])
      sleep 0.5
      Process.kill("KILL", handle[:pid]) if process_alive?(handle[:pid])
      Process.waitpid(handle[:pid])
    end
  rescue Errno::ESRCH, Errno::ECHILD
    # Already dead
  ensure
    handle[:stdout]&.close unless handle[:stdout]&.closed?
    handle[:stderr]&.close unless handle[:stderr]&.closed?
  end

  def process_alive?(pid)
    Process.kill(0, pid)
    true
  rescue Errno::ESRCH
    false
  end

  def project_root
    File.expand_path("../../..", __dir__)
  end

  def wait_until(timeout: 5, poll: 0.1)
    deadline = Time.now + timeout
    sleep poll until yield || Time.now > deadline
  end

  def create_job_instance(bpmn_process_id = "job-process")
    request = Busybee::GRPC::CreateProcessInstanceRequest.new(
      bpmnProcessId: bpmn_process_id,
      version: -1,
      variables: "{}"
    )
    response = grpc_client.create_process_instance(request)
    response.processInstanceKey
  end

  def cancel_instance(key)
    request = Busybee::GRPC::CancelProcessInstanceRequest.new(processInstanceKey: key)
    grpc_client.cancel_process_instance(request)
  rescue GRPC::NotFound
    # Already completed
  end

  # --- Tests ---

  describe "end-to-end job processing" do
    before { client.deploy_process(job_bpmn_path) }

    it "processes a job with a positional worker argument" do
      handle = spawn_cli("CLITestWorker")

      instance_key = create_job_instance
      begin
        wait_until(timeout: 15) { signal_file_lines.any? }

        status = stop_cli(handle)

        expect(signal_file_lines.length).to eq(1)
        expect(status.exitstatus).to eq(0)
      ensure
        cancel_instance(instance_key)
      end
    end

    it "processes multiple jobs across poll iterations" do
      handle = spawn_cli("CLITestWorker")
      instance_keys = []

      begin
        # First batch
        2.times { instance_keys << create_job_instance }
        wait_until(timeout: 15) { signal_file_lines.length >= 2 }

        # Second batch — requires a new poll iteration
        instance_keys << create_job_instance
        wait_until(timeout: 15) { signal_file_lines.length >= 3 }

        status = stop_cli(handle)

        expect(signal_file_lines.length).to eq(3)
        expect(signal_file_lines.uniq.length).to eq(3)
        expect(status.exitstatus).to eq(0)
      ensure
        instance_keys.each { |key| cancel_instance(key) }
      end
    end
  end

  describe "YAML configuration" do
    let(:yaml_dir) { File.join(project_root, "tmp", "cli_integration_yaml") }

    before do
      FileUtils.mkdir_p(yaml_dir)
      client.deploy_process(job_bpmn_path)
      client.deploy_process(multi_job_bpmn_path)
    end

    after { FileUtils.rm_rf(yaml_dir) }

    def write_yaml(filename, content)
      path = File.join(yaml_dir, filename)
      File.write(path, content)
      path
    end

    it "processes jobs using a YAML config file" do
      yaml_path = write_yaml("single.yml", <<~YAML)
        worker_mode: polling
        workers:
          - CLITestWorker
      YAML

      handle = spawn_cli("--config", yaml_path)
      instance_key = create_job_instance

      begin
        wait_until(timeout: 15) { signal_file_lines.any? }

        status = stop_cli(handle)

        expect(signal_file_lines.length).to eq(1)
        expect(status.exitstatus).to eq(0)
      ensure
        cancel_instance(instance_key)
      end
    end

    it "processes jobs with multiple workers from YAML config" do
      yaml_path = write_yaml("multi.yml", <<~YAML)
        workers:
          - CLITestWorkerA:
              worker_mode: polling
          - CLITestWorkerB:
              worker_mode: polling
              request_timeout: 1000
      YAML

      # Start CLI before creating instances (streaming workers need the stream open)
      handle = spawn_cli("--config", yaml_path)
      sleep 3 # Must exceed bundle exec + gem load time (~1.2s) to ensure workers are streaming

      instance_key = create_job_instance("multi-job-process")

      begin
        wait_until(timeout: 15) do
          lines = signal_file_lines
          lines.any? { |l| l.start_with?("a:") } && lines.any? { |l| l.start_with?("b:") }
        end

        status = stop_cli(handle)

        lines = signal_file_lines
        expect(lines.count { |l| l.start_with?("a:") }).to eq(1)
        expect(lines.count { |l| l.start_with?("b:") }).to eq(1)
        expect(status.exitstatus).to eq(0)
      ensure
        cancel_instance(instance_key)
      end
    end

    it "respects per-worker config overrides from YAML" do
      yaml_path = write_yaml("overrides.yml", <<~YAML)
        worker_mode: streaming
        workers:
          - CLITestWorker:
              worker_mode: polling
      YAML

      handle = spawn_cli("--config", yaml_path)
      instance_key = create_job_instance

      begin
        wait_until(timeout: 15) { signal_file_lines.any? }

        status = stop_cli(handle)

        expect(signal_file_lines.length).to eq(1)
        expect(status.exitstatus).to eq(0)
      ensure
        cancel_instance(instance_key)
      end
    end
  end

  describe "graceful shutdown" do
    before { client.deploy_process(job_bpmn_path) }

    it "exits cleanly on TERM signal with no pending jobs" do
      handle = spawn_cli("CLITestWorker")
      sleep 3 # Must exceed bundle exec + gem load time (~1.2s) to ensure signal handlers are installed

      status = stop_cli(handle)

      expect(status.exitstatus).to eq(0)
      expect(signal_file_lines).to be_empty
    end

    it "exits cleanly on INT signal" do
      handle = spawn_cli("CLITestWorker")
      sleep 3

      status = stop_cli(handle, signal: "INT")

      expect(status.exitstatus).to eq(0)
    end

    it "completes in-flight jobs before exiting" do
      handle = spawn_cli("CLITestWorker")
      instance_key = create_job_instance

      begin
        wait_until(timeout: 15) { signal_file_lines.any? }

        status = stop_cli(handle)

        expect(signal_file_lines.length).to eq(1)
        expect(status.exitstatus).to eq(0)
      ensure
        cancel_instance(instance_key)
      end
    end
  end

  describe "error scenarios" do
    it "exits with error when worker class is not found" do
      handle = spawn_cli("NonexistentWorker")
      status = wait_for_exit(handle, timeout: 10)

      output = drain_output(handle)

      expect(status.exitstatus).not_to eq(0)
      expect(output[:stderr]).to include("NonexistentWorker")
    end

    it "exits with error when no workers are specified" do
      handle = spawn_cli
      status = wait_for_exit(handle, timeout: 10)

      output = drain_output(handle)

      expect(status.exitstatus).not_to eq(0)
      expect(output[:stderr]).to include("No worker")
    end

    it "exits with error for a bad config file path" do
      handle = spawn_cli("--config", "/nonexistent/path/config.yml")
      status = wait_for_exit(handle, timeout: 10)

      expect(status.exitstatus).not_to eq(0)
    end

    it "exits with error when --config and --worker-mode are both provided" do
      handle = spawn_cli("--config", "dummy.yml", "--worker-mode", "polling")
      status = wait_for_exit(handle, timeout: 10)

      output = drain_output(handle)

      expect(status.exitstatus).not_to eq(0)
      expect(output[:stderr]).to include("mutually exclusive")
    end

    it "exits with error for a bogus cluster address" do
      handle = spawn_cli("-a", "localhost:1", "CLITestWorker")
      status = wait_for_exit(handle, timeout: 15)

      expect(status.exitstatus).not_to eq(0)
    end
  end
end
