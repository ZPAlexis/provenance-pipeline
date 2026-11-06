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

    COMMANDS = %w[extract resolve own_board match verify check boards suggest related describe draft review fit].freeze
    # The commands whose targets and results quote the resume (2c, 2d, 2f): a run's files are removed as soon as its
    # results are read, since the record keeps what was written from them.
    PRIVATE = %w[draft review fit].freeze

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

    # A new run's directory: its targets, results, and report, under tmp/verifier/ (ignored:
    # results name real companies from the private target list).
    def self.dir_for(name)
      Rails.root.join("tmp/verifier/#{Time.current.utc.strftime('%Y%m%dT%H%M%SZ')}-#{name}")
    end

    # Removes a run's targets and results, and its directory once nothing else is in it: for a run whose files quote
    # the resume. Its results are already read by then.
    def self.forget!(run_dir)
      dir = Pathname.new(run_dir)
      %w[targets.json results.jsonl].each { |name| FileUtils.rm_f(dir.join(name)) }
      dir.rmdir if dir.directory? && dir.empty?
    end

    # The run directories under `root` left by a command whose files quote the resume (kept before forget! existed).
    def self.private_runs(root = Rails.root.join("tmp/verifier"))
      return [] unless root.directory?

      root.children.select { |dir| dir.directory? && dir.basename.to_s.split("-").intersect?(PRIVATE) }.sort
    end

    attr_reader :run_dir

    # `free: true` starts the worker with no API key at all, whatever the file holds or the shell has: nothing it
    # runs can reach the LLM, so the run costs nothing by construction (4b: the read on tracking a proposal). A step
    # that would need the LLM stops the run instead, as a missing key does.
    def initialize(run_dir:, model: nil, credential_file: CREDENTIAL_FILE, process: Process, free: false)
      @run_dir = Pathname.new(run_dir)
      @model = model
      @credential_file = Pathname.new(credential_file)
      @process = process
      @free = free
    end

    def credential?
      api_key.present?
    end

    def free? = @free

    # extract: targets are [{ id:, url:, label:, domain:, name: }], one PageResult each.
    # resolve: targets are [{ id:, label:, domain:, name:, known_url: }], one ResolutionResult each.
    # own_board: targets are [{ id:, label:, domain:, name:, url: }], one ResolutionResult each: the board a proposal
    # named, read through its API, and whose it is; never the LLM.
    # match: targets are [{ id:, label:, page_check_id:, complete:, listings:, postings: }], one MatchResult
    # each; nothing is fetched. `flags` are passed through, e.g. ["--no-llm"].
    # verify: targets from Verifier::Targets.verify, one VerificationResult each.
    # check: targets from Verifier::Targets.check (one posting each), one VerificationResult each.
    # boards: targets from Verifier::Targets.board, one BoardResult each; never calls the LLM.
    # suggest: targets from Verifier::Targets.suggest, one SuggestionResult each; nothing fetched, no LLM.
    # related: one search profile's titles, one RelatedResult with titles proposed by one LLM call.
    # describe: targets from Verifier::Descriptions.target, one DescriptionResult each; never calls the LLM.
    # draft: targets from Drafts.target, one DraftResult each: one LLM call, nothing fetched, nothing sent.
    # review: targets from ResumeReviews.target, one ReviewResult each: one LLM call, nothing fetched.
    # fit: targets from FitScores.target, one FitResult each: one LLM call, nothing fetched.
    def run(targets, command: "extract", flags: [])
      raise ArgumentError, "unknown worker command #{command.inspect}" unless COMMANDS.include?(command)

      FileUtils.mkdir_p(@run_dir)
      targets_path = @run_dir.join("targets.json")
      results_path = @run_dir.join("results.jsonl")
      targets_path.write(JSON.pretty_generate(targets: targets))

      pid = @process.spawn(worker_env, *command_line(command, targets_path, results_path, flags), chdir: ROOT.to_s)
      _, status = @process.wait2(pid)
      unless status.exitstatus.zero? || STOPPED.key?(status.exitstatus)
        raise Error, "the verification worker exited with status #{status.exitstatus}"
      end

      Run.new(dir: @run_dir, results: self.class.read_results(results_path), stopped: STOPPED[status.exitstatus])
    end

    # A results file, checked line by line against the result version this code
    # reads. Every reader goes through here: a run just made, and a saved run
    # re-scored or recorded later (RESULTS=). A result from another version fails
    # loudly rather than being scored or written with what its fields used to mean.
    def self.read_results(path)
      path = Pathname.new(path)
      return [] unless path.exist?

      path.each_line.with_index(1).map do |line, number|
        result = JSON.parse(line)
        unless result["schema_version"] == RESULT_SCHEMA_VERSION
          raise Error, "#{path}:#{number}: result schema version #{result['schema_version'].inspect}, but this " \
                       "code reads version #{RESULT_SCHEMA_VERSION}: read it again, or score it with the code of its version"
        end

        result
      end
    end

    private

    def command_line(command, targets_path, results_path, flags)
      [ "uv", "run", "--quiet", "verifier", command,
        "--targets", targets_path.to_s, "--out", results_path.to_s,
        *([ "--model", @model ] if @model), *flags ]
    end

    # A nil value unsets the variable in the worker's environment.
    def worker_env
      return { "ANTHROPIC_API_KEY" => nil, "ANTHROPIC_AUTH_TOKEN" => nil } if @free

      api_key ? { "ANTHROPIC_API_KEY" => api_key } : {}
    end

    def api_key
      return if @free
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
  end
end
