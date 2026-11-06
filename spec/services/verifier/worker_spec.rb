require "rails_helper"

RSpec.describe Verifier::Worker do
  # Stands in for Process: records the spawn, writes the results file the real
  # worker would have written, and exits with the given status.
  let(:fake_process_class) do
    Class.new do
      attr_reader :spawned

      def initialize(exitstatus: 0, results: [])
        @exitstatus = exitstatus
        @results = results
      end

      def spawn(env, *command, chdir:)
        @spawned = { env: env, command: command, chdir: chdir }
        out = command[command.index("--out") + 1]
        File.write(out, @results.map { |result| "#{result.to_json}\n" }.join)
        4242
      end

      def wait2(pid)
        [ pid, Struct.new(:exitstatus).new(@exitstatus) ]
      end
    end
  end

  def fake_process(**options) = fake_process_class.new(**options)

  # Found 2026-10-26: `fit` was added to the worker but not here, and every spec used a stand-in worker, so the first
  # real run was refused. The commands Rails may run are the worker's own, read from its CLI.
  it "knows every command the worker's CLI has, and no other" do
    cli = Rails.root.join("workers/verifier/src/verifier/cli.py").read

    expect(described_class::COMMANDS).to match_array(cli.scan(/add_parser\(\s*"(\w+)"/).flatten)
  end

  let(:dir) { Pathname.new(Dir.mktmpdir) }
  let(:credential_file) { dir.join("anthropic.env") }
  let(:targets) { [ { id: "c1", url: "https://acme.example/careers", label: "Acme" } ] }

  def result(**overrides)
    { "schema_version" => 2, "target_id" => "c1", "outcome" => "ok", "listing_count" => 3 }.merge(overrides)
  end

  def worker(process, **options)
    described_class.new(run_dir: dir.join("run"), credential_file: credential_file, process: process, **options)
  end

  after { FileUtils.remove_entry(dir) }

  it "hands the worker a targets file and reads back its results" do
    process = fake_process(results: [ result ])

    run = worker(process).run(targets)

    expect(JSON.parse(dir.join("run/targets.json").read)).to eq("targets" => targets.map(&:stringify_keys))
    expect(process.spawned[:command]).to start_with("uv", "run", "--quiet", "verifier", "extract")
    expect(process.spawned[:chdir]).to eq(Rails.root.join("workers/verifier").to_s)
    expect(run.results).to eq([ result ])
    expect(run.stopped).to be_nil
  end

  it "passes a model when one is chosen" do
    process = fake_process

    worker(process, model: "claude-sonnet-5").run(targets)

    expect(process.spawned[:command].last(2)).to eq([ "--model", "claude-sonnet-5" ])
  end

  describe "the API credential" do
    it "is read from the credential file and given to the worker process alone" do
      credential_file.write("export ANTHROPIC_API_KEY=\"sk-test-123\"\n")
      process = fake_process

      worker(process).run(targets)

      expect(process.spawned[:env]).to eq("ANTHROPIC_API_KEY" => "sk-test-123")
      expect(ENV["ANTHROPIC_API_KEY"]).not_to eq("sk-test-123")
    end

    # 4b: the read on tracking a proposal is free by construction. The key is unset in the worker's environment even
    # when the file holds one, or the shell had one, so nothing the worker runs can reach the LLM.
    it "is never given, and is taken out of the worker's environment, when the run is free" do
      credential_file.write("export ANTHROPIC_API_KEY=\"sk-test-123\"\n")
      process = fake_process

      free = worker(process, free: true)
      free.run(targets, command: "own_board")

      expect([ free.free?, free.credential? ]).to eq([ true, false ])
      expect(process.spawned[:env]).to eq("ANTHROPIC_API_KEY" => nil, "ANTHROPIC_AUTH_TOKEN" => nil)
      expect(process.spawned[:command]).to include("own_board")
    end

    it "is simply absent when there is no credential file" do
      process = fake_process

      expect(worker(process).credential?).to be(false)
      worker(process).run(targets)
      expect(process.spawned[:env]).to eq({})
    end
  end

  it "keeps the finished results of a run that stopped because credit ran out" do
    run = worker(fake_process(exitstatus: 3, results: [ result ])).run(targets)

    expect(run.stopped).to eq("API credit exhausted")
    expect(run.results.size).to eq(1)
  end

  it "raises when the worker fails outright" do
    expect { worker(fake_process(exitstatus: 1)).run(targets) }.to raise_error(described_class::Error, /status 1/)
  end

  it "refuses results in a schema it does not know" do
    process = fake_process(results: [ result("schema_version" => 1) ])

    expect { worker(process).run(targets) }.to raise_error(described_class::Error, /schema version 1/)
  end

  # A saved run read again later (RESULTS=) passes the same check as a run just made.
  it "checks a saved results file against the version this code reads, naming the line" do
    saved = dir.join("results.jsonl")
    saved.write("#{result.to_json}\n#{result('schema_version' => 3).to_json}\n")

    expect { described_class.read_results(saved) }
      .to raise_error(described_class::Error, %r{results\.jsonl:2: result schema version 3, but this code reads version 2})
    expect(described_class.read_results(dir.join("missing.jsonl"))).to eq([])

    saved.write("#{result.to_json}\n")
    expect(described_class.read_results(saved.to_s)).to eq([ result ])
  end

  it "runs resolution when asked, naming the run after its directory" do
    process = fake_process

    run = worker(process).run([ { id: "c1", label: "Acme", domain: "acme.example" } ], command: "resolve")

    expect(process.spawned[:command]).to start_with("uv", "run", "--quiet", "verifier", "resolve")
    expect(run.id).to eq("run")
  end

  it "passes flags through to the worker" do
    process = fake_process

    worker(process).run([ { id: "c1", complete: true, listings: [], postings: [] } ], command: "match", flags: [ "--no-llm" ])

    expect(process.spawned[:command]).to start_with("uv", "run", "--quiet", "verifier", "match")
    expect(process.spawned[:command].last).to eq("--no-llm")
  end

  it "refuses a command the worker does not have" do
    expect { worker(fake_process).run(targets, command: "delete") }.to raise_error(ArgumentError, /delete/)
  end

  # Review pass R3: a draft's, a review's or a fit's files quote the resume, so they go once read.
  it "forgets a run's targets and results, and its directory once nothing else is in it" do
    Dir.mktmpdir do |root|
      run = Pathname.new(root).join("20261102T120000Z-fit").tap(&:mkpath)
      %w[targets.json results.jsonl].each { |name| run.join(name).write("{}") }
      kept = Pathname.new(root).join("20261102T120000Z-draft").tap(&:mkpath)
      kept.join("results.jsonl").write("{}")
      kept.join("notes.txt").write("something else")

      described_class.forget!(run)
      described_class.forget!(kept)

      expect(run).not_to exist
      expect(kept.children.map { |file| file.basename.to_s }).to eq(%w[notes.txt])
      expect { described_class.forget!(run) }.not_to raise_error # gone already
    end
  end

  it "finds the run directories left by a command whose files quote the resume, and only those" do
    Dir.mktmpdir do |root|
      root = Pathname.new(root)
      %w[20261019T120000Z-draft 20261026T120000Z-fit 20261027T120000Z-review 20261019T120000Z-probe-draft-7b21b2
         20261014T120000Z-verify 20261016T120000Z-describe 20261009T120000Z-resolve].each { |name| root.join(name).mkpath }
      root.join("20261020T120000Z-fit.log").write("a file, not a run")

      expect(described_class.private_runs(root).map { |dir| dir.basename.to_s })
        .to eq(%w[20261019T120000Z-draft 20261019T120000Z-probe-draft-7b21b2 20261026T120000Z-fit 20261027T120000Z-review])
      expect(described_class.private_runs(root.join("missing"))).to eq([])
    end
  end
end
