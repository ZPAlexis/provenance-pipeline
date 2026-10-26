require "rails_helper"

RSpec.describe FitScores do
  let!(:company) { create(:company, :resolved, name: "Acme", domain: "acme.example") }
  let!(:role) { create(:posting, company: company, role_title: "Sales Engineer", tracking: "tracked", job_url: "https://acme.example/jobs/1") }
  let!(:other) { create(:posting, company: company, role_title: "Solutions Engineer", tracking: "suggested", job_url: "https://acme.example/jobs/2") }
  let!(:profile) { SearchProfile.create!(titles: [ "Sales Engineer" ], places: [ "Brazil" ]) }
  let(:run_dir) { Rails.root.join("tmp/verifier/20261026T120000Z-fit-spec") }

  after { FileUtils.rm_rf(run_dir) }

  def resume_text = "Jordan Sample\nSales engineer, eight years.\n- Ran discovery for 35 accounts a year."

  def keep_resume(text = resume_text) = Resumes.keep!(profile, text: text)

  def describe_role(posting = role, text = "Discovery. Spanish required.")
    posting.role_descriptions.create!(text: text, content_hash: Resume.digest(text), read_via: "render", url: posting.job_url, run_id: "r1",
                                      first_read_at: 1.day.ago, last_read_at: 1.day.ago)
  end

  # Stands in for Verifier::Worker, as in the drafts spec: keeps what it was asked and leaves a targets file.
  let(:worker_class) do
    Class.new do
      attr_reader :asked, :run_dir

      def initialize(results, run_dir, stopped: nil)
        @results, @run_dir, @stopped = results, run_dir, stopped
      end

      def run(targets, command:)
        @asked = { targets: targets, command: command }
        FileUtils.mkdir_p(@run_dir)
        @run_dir.join("targets.json").write(JSON.generate(targets: targets))
        Verifier::Worker::Run.new(dir: @run_dir, results: @results, stopped: @stopped)
      end
    end
  end

  def llm(**fields)
    { "model" => "claude-haiku-4-5-20251001", "settings" => {}, "purpose" => "fit", "prompt_version" => "f1",
      "input_tokens" => 4_000, "output_tokens" => 600, "cost_usd" => 0.007, **fields }
  end

  def weighed(posting = role, **fields)
    { "kind" => "fit", "target_id" => posting.id, "outcome" => "ok", "score" => 72, "level" => "Mid-level; the resume shows eight years",
      "matches" => [ { "point" => "Discovery at volume", "lines" => [ { "line" => 3, "text" => "- Ran discovery for 35 accounts a year." } ] } ],
      "gaps" => [ { "asks" => "Spanish", "note" => "Not shown." } ], "why" => "Strong on discovery; Spanish is missing.",
      "dropped_lines" => 0, "llm" => llm, **fields }
  end

  def weigh(postings, *results, stopped: nil)
    worker = worker_class.new(results, run_dir, stopped: stopped)
    [ described_class.weigh!(postings, worker: worker), worker ]
  end

  it "weighs a role as the fit scorer, under a credential for the run holding fit:write alone, audited without its text" do
    resume = keep_resume
    description = describe_role

    result, worker = weigh(role, weighed)

    expect(worker.asked[:command]).to eq("fit")
    expect(worker.asked[:targets].sole).to eq(id: role.id, label: "Acme / Sales Engineer", role_title: "Sales Engineer", company: "Acme",
                                              location: role.location, description: "Discovery. Spanish required.", resume: resume_text,
                                              titles: [ "Sales Engineer" ])
    expect(run_dir.join("targets.json")).not_to exist # it held the whole resume
    score = role.fit_scores.sole
    expect(score).to have_attributes(score: 72, level: "Mid-level; the resume shows eight years", written_by: "agent:fit_scorer",
                                     resume: resume, role_description: description, why: "Strong on discovery; Spanish is missing.",
                                     run_id: "20261026T120000Z-fit-spec", writer: "the fit scorer")
    expect(score.llm_call).to have_attributes(purpose: "fit", cost_usd: 0.007)
    expect(result).to have_attributes(finished?: true, answer: "weighed", cost_usd: 0.007, tally: { "weighed" => 1 },
                                      summary: "Weighed: 72 for Sales Engineer at Acme (1 match, 1 gap).")
    expect(AgentCredential.sole).to have_attributes(actor: "agent:fit_scorer", scopes: %w[fit:write], status: "revoked",
                                                    purpose: "fit: Sales Engineer at Acme")
    event = AuditEvent.find_by!(target: score)
    expect(event).to have_attributes(actor: "agent:fit_scorer", model_version: "claude-haiku-4-5-20251001",
                                     reasoning: "Weighed: 72 for Sales Engineer at Acme (1 match, 1 gap).")
    expect(event.changes_made).to include("score" => [ nil, 72 ], "matches" => [ nil, 1 ], "gaps" => [ nil, 1 ])
    expect(event.changes_made.to_json).not_to include("discovery", "Spanish", "Jordan")
  end

  it "weighs a batch in one run, leaving a role with no description unweighed, and says what came of each" do
    keep_resume
    describe_role
    describe_role(other, "Back-end Python engineering.")
    third = create(:posting, company: company, role_title: "Account Executive", tracking: "tracked")

    result, worker = weigh([ role, other, third ], weighed("score" => 81), weighed(other, "outcome" => "error", "reason" => "llm_refusal",
                                                                                        "llm" => llm("cost_usd" => 0.002)))

    expect(worker.asked[:targets].map { |target| target[:id] }).to eq([ role.id, other.id ])
    expect(AgentCredential.sole).to have_attributes(purpose: "fit: 2 roles", scopes: %w[fit:write])
    expect(result).to have_attributes(finished?: true, cost_usd: 0.009, tally: { "weighed" => 1, "not weighed" => 2 },
                                      summary: "Weighed: 81 for Sales Engineer at Acme (1 match, 1 gap); 2 roles not weighed.")
    expect(result.unweighed.to_h).to eq(third => "no description on record", other => "the AI could not weigh it (llm_refusal)")
    expect(LlmCall.where(purpose: "fit").count).to eq(2) # the failed call is billed all the same
  end

  it "keeps nothing a result breaks the contract with, and says when the run stopped first" do
    keep_resume
    describe_role
    describe_role(other)

    result, = weigh([ role, other ], weighed("score" => 140), stopped: "API credit exhausted")

    expect(FitScore.count).to eq(0)
    expect(result.unweighed.to_h).to eq(role => "not recorded: score must be a whole number from 0 to 100",
                                        other => "the run stopped first (API credit exhausted)")
    expect(result).to have_attributes(finished?: false, answer: "not weighed")
  end

  it "refuses before any run without a resume, and finds the unscored: none yet, or stale" do
    describe_role
    expect { weigh(role) }.to raise_error(ArgumentError, "weighing needs a resume, saved on the Profile page, first")
    expect { described_class.weigh!([]) }.to raise_error(ArgumentError, "name a role to weigh")

    keep_resume
    weigh(role, weighed)
    expect(described_class.unscored([ role, other ])).to eq([ other ])
    expect(described_class.undescribed([ role, other ])).to eq([ other ])

    keep_resume("Jordan Sample\nA newer resume.")
    expect(described_class.unscored([ role, other ])).to eq([ role, other ])
    expect(role.fit_scores.sole.stale_for(profile.resumes.newest_first.first, role.role_descriptions.sole)).to eq([ "the resume" ])
  end

  it "offers tracked and suggested roles not known to be gone, and keeps every score, the newest shown" do
    gone = create(:posting, company: company, role_title: "Designer", tracking: "tracked", verification_state: "not_found",
                            last_checked_at: 1.day.ago)
    dismissed = create(:posting, company: company, role_title: "Recruiter", tracking: "dismissed")
    keep_resume
    describe_role
    weigh(role, weighed("score" => 60))
    weigh(role, weighed("score" => 75))

    expect(described_class.offered).to contain_exactly(role, other)
    expect([ gone, dismissed ]).to all(satisfy { |posting| !described_class.offered.include?(posting) })
    expect(described_class.newest.transform_values(&:score)).to eq(role.id => 75)
    expect(role.fit_scores.count).to eq(2)
  end

  it "is refused to touch a role, or to change a score, even as the fit scorer" do
    keep_resume
    describe_role
    weigh(role, weighed)
    score = role.fit_scores.sole

    expect { as_agent("agent:fit_scorer") { role.update!(tracking: "dismissed") } }.to raise_error(Authority::Denied, /may not update a posting/)
    expect { as_agent("agent:fit_scorer") { score.update!(score: 99) } }.to raise_error(Authority::Denied, /may not update a fit score/)
    expect { FitScore.create!(posting: role, score: 101, why: "x", resume_hash: "h", description_hash: "h", written_by: "agent:fit_scorer") }
      .to raise_error(ActiveRecord::RecordInvalid, /Score must be in 0..100/)
  end
end
