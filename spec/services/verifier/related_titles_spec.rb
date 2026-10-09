require "rails_helper"

RSpec.describe Verifier::RelatedTitles do
  let(:profile) { SearchProfile.new(titles: [ "Solutions Engineer" ], places: [ "Brazil" ], work_modes: [ "remote" ]) }
  let(:company) { create(:company, :resolved, name: "Zendesk") }

  # Stands in for Verifier::Worker: records what it was asked to run, and hands back the results given.
  let(:worker_class) do
    Class.new do
      attr_reader :asked

      def initialize(results, stopped: nil) = (@results, @stopped = results, stopped)

      def run(targets, command:)
        @asked = { targets: targets, command: command }
        Verifier::Worker::Run.new(dir: Pathname.new("tmp/verifier/20261009T120000Z-related"), results: @results, stopped: @stopped)
      end
    end
  end

  let(:llm) do
    { "model" => "claude-haiku-4-5-20251001", "settings" => {}, "purpose" => "relate", "prompt_version" => "r1",
      "input_tokens" => 420, "output_tokens" => 310, "cost_usd" => 0.002 }
  end

  def related(proposals, **overrides)
    { "kind" => "related", "target_id" => "unsaved", "outcome" => "ok", "llm" => llm,
      "proposals" => proposals.map { |title, language| { "title" => title, "language" => language, "reason" => "Same work." } } }
      .merge(overrides)
  end

  def fit(title, listing)
    Verifier::Suggestions::Fit.new(company: company, listing: { "title" => listing }, title: title, level: nil, place: "Brazil",
                                   work_mode: "remote", suggested: true, ruled_out: nil, notes: [], reasoning: "Fits.", on_record: nil)
  end

  it "proposes titles from one AI call, with the new roles each would add, and keeps what the call cost" do
    worker = worker_class.new([ related([ [ "Sales Engineer", "English" ], [ "Arquiteto de Soluções", "Portuguese" ] ]) ])
    previewed = nil
    preview = lambda do |wider|
      previewed = wider
      Verifier::Suggestions::Preview.new(companies: 1, unread: 0, weighed: 3, read_between: [], problems: [],
                                         fits: [ fit("Solutions Engineer", "Solutions Engineer"), fit("Sales Engineer", "Sales Engineer"),
                                                 fit("Sales Engineer", "Senior Sales Engineer") ])
    end

    result = described_class.propose(profile, worker: worker, preview: preview)

    expect(worker.asked).to eq(command: "related", targets: [ { id: "unsaved", titles: [ "Solutions Engineer" ], excluded: [], places: [ "Brazil" ] } ])
    expect(previewed).to have_attributes(titles: [ "Solutions Engineer", "Sales Engineer", "Arquiteto de Soluções" ], work_modes: [ "remote" ])
    expect(result.proposals.map { |p| [ p.title, p.adds, p.examples ] }).to eq(
      [ [ "Sales Engineer", 2, [ "Sales Engineer at Zendesk", "Senior Sales Engineer at Zendesk" ] ], [ "Arquiteto de Soluções", 0, [] ] ]
    )
    expect(result.cost_usd).to eq(0.002)
    expect(LlmCall.sole).to have_attributes(purpose: "relate", page_check: nil, run_id: "20261009T120000Z-related", cost_usd: 0.002)
  end

  it "says why when the AI could not propose, keeping what the call cost all the same" do
    worker = worker_class.new([ related([], "outcome" => "error", "reason" => "llm_output_invalid") ])

    result = described_class.propose(profile, worker: worker, preview: ->(_) { raise "never previewed" })

    expect(result.problems).to eq([ "The AI could not propose titles (llm_output_invalid)." ])
    expect(LlmCall.count).to eq(1)
  end

  it "says so when the worker stopped before an answer, as without a credential" do
    result = described_class.propose(profile, worker: worker_class.new([], stopped: "API credential missing, rejected, or not validated"))

    expect(result.problems).to eq([ "Stopped before an answer: API credential missing, rejected, or not validated." ])
    expect(LlmCall.count).to eq(0)
  end
end
