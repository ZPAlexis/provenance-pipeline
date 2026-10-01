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
end
