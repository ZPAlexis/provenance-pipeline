require "json"

module Verifier
  # Runs the Python verification worker across its single boundary: a targets
  # file in, a results file out. The worker never touches the database;
  # everything it finds comes back through here, and from 1.2b on through the
  # one audited write path.
  class Worker
    ROOT = Rails.root.join("workers/verifier")

    # Kept outside the repo and read only here, then handed to the worker
    # process alone. Never exported to the shell: a global ANTHROPIC_API_KEY
    # would silently switch Claude Code from the subscription to API billing.
    CREDENTIAL_FILE = Pathname.new(Dir.home).join(".config/provenance-pipeline/anthropic.env")

    RESULT_SCHEMA_VERSION = 2

    COMMANDS = %w[extract resolve].freeze

    # Exit codes from workers/verifier/src/verifier/cli.py for a run that
    # stopped early on purpose, keeping every result it finished.
    STOPPED = {
      3 => "API credit exhausted",
      4 => "API credential missing, rejected, or not validated",
      5 => "the LLM service kept failing"
    }.freeze

    class Error < StandardError; end

    Run = Struct.new(:dir, :results, :stopped, keyword_init: true) do
      # What its page checks and LLM calls are filed under: the directory holding its targets and results.
      def id = dir.basename.to_s
    end

    def initialize(run_dir:, model: nil, credential_file: CREDENTIAL_FILE, process: Process)
      @run_dir = Pathname.new(run_dir)
      @model = model
      @credential_file = Pathname.new(credential_file)
      @process = process
    end

    def credential?
      api_key.present?
    end

    # extract: targets are [{ id:, url:, label:, domain:, name: }], one PageResult each.
    # resolve: targets are [{ id:, label:, domain:, name:, known_url: }], one ResolutionResult each.
    def run(targets, command: "extract")
      raise ArgumentError, "unknown worker command #{command.inspect}" unless COMMANDS.include?(command)

      FileUtils.mkdir_p(@run_dir)
      targets_path = @run_dir.join("targets.json")
      results_path = @run_dir.join("results.jsonl")
      targets_path.write(JSON.pretty_generate(targets: targets))

      pid = @process.spawn(worker_env, *command_line(command, targets_path, results_path), chdir: ROOT.to_s)
      _, status = @process.wait2(pid)
      unless status.exitstatus.zero? || STOPPED.key?(status.exitstatus)
        raise Error, "the verification worker exited with status #{status.exitstatus}"
      end

      Run.new(dir: @run_dir, results: read_results(results_path), stopped: STOPPED[status.exitstatus])
    end

    private

    def command_line(command, targets_path, results_path)
      [ "uv", "run", "--quiet", "verifier", command,
        "--targets", targets_path.to_s, "--out", results_path.to_s,
        *([ "--model", @model ] if @model) ]
    end

    def worker_env
      api_key ? { "ANTHROPIC_API_KEY" => api_key } : {}
    end

    def api_key
      return @api_key if defined?(@api_key)

      @api_key = @credential_file.exist? ? parse_key(@credential_file.read) : nil
    end

    def parse_key(contents)
      contents.each_line do |line|
        name, value = line.strip.delete_prefix("export ").split("=", 2)
        return value.strip.delete("\"'").presence if name == "ANTHROPIC_API_KEY" && value
      end
      nil
    end

    def read_results(path)
      return [] unless path.exist?

      path.each_line.map do |line|
        result = JSON.parse(line)
        unless result["schema_version"] == RESULT_SCHEMA_VERSION
          raise Error, "unexpected result schema version #{result["schema_version"].inspect}"
        end

        result
      end
    end
  end
end
