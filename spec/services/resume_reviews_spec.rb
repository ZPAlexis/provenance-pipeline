require "rails_helper"

RSpec.describe ResumeReviews do
  let!(:company) { create(:company, :resolved, name: "Acme", domain: "acme.example") }
  let!(:role) { create(:posting, company: company, role_title: "Sales Engineer", tracking: "tracked", job_url: "https://acme.example/jobs/1") }
  let!(:application) { create(:application, posting: role, notes: "They care about discovery.") }
  let!(:profile) { SearchProfile.create!(titles: [ "Sales Engineer" ], places: [ "Brazil" ]) }
  let(:run_dir) { Rails.root.join("tmp/verifier/20261023T120000Z-review-spec") }

  after { FileUtils.rm_rf(run_dir) }

  def resume_text = "Jordan Sample\nSales engineer, eight years.\n- Ran discovery for 35 accounts a year."

  def ready
    resume = Resumes.keep!(profile, text: resume_text)
    description = role.role_descriptions.create!(text: "Discovery. Spanish required.", content_hash: Resume.digest("Discovery. Spanish required."),
                                                 read_via: "render", url: role.job_url, run_id: "r1", first_read_at: 1.day.ago,
                                                 last_read_at: 1.day.ago)
    [ resume, description ]
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
    { "model" => "claude-opus-5-5", "settings" => { "output_config" => { "effort" => "medium" } }, "purpose" => "review",
      "prompt_version" => "12a32d559f0c", "input_tokens" => 4_000, "output_tokens" => 2_000, "cost_usd" => 0.056, **fields }
  end

  def reviewed(**fields)
    { "kind" => "review", "target_id" => application.id, "outcome" => "ok", "language" => "English",
      "strengths" => [ { "point" => "Discovery at volume", "lines" => [ { "line" => 3, "text" => "- Ran discovery for 35 accounts a year." } ] } ],
      "gaps" => [ { "asks" => "Spanish", "note" => "Not shown." } ],
      "suggestions" => [ { "change" => "Lead with discovery", "lines" => [ { "line" => 3, "text" => "- Ran discovery for 35 accounts a year." } ] } ],
      "note" => "A close fit.", "dropped_lines" => 0, "llm" => llm, **fields }
  end

  def write(*results, stopped: nil, **options)
    worker = worker_class.new(results, run_dir, stopped: stopped)
    [ described_class.write!(application, worker: worker, **options), worker ]
  end

  it "writes a review as the drafter, under a credential for the run holding resume_reviews:write alone" do
    resume, description = ready

    written, worker = write(reviewed)

    expect(worker.asked[:command]).to eq("review")
    expect(worker.asked[:targets].sole).to include(id: application.id, resume: resume_text, description: "Discovery. Spanish required.",
                                                   notes: "They care about discovery.", language: "English", places: [ "Brazil" ])
    expect(run_dir.join("targets.json")).not_to exist
    review = application.resume_reviews.sole
    expect(review).to have_attributes(written_by: "agent:drafter", resume: resume, role_description: description, note: "A close fit.",
                                      run_id: "20261023T120000Z-review-spec")
    expect(review.llm_call).to have_attributes(purpose: "review", cost_usd: 0.056)
    expect(written).to have_attributes(finished?: true, answer: "reviewed", cost_usd: 0.056,
                                       summary: "Resume review in English: 1 strength, 1 gap, 1 suggestion.")
    expect(AgentCredential.sole).to have_attributes(actor: "agent:drafter", scopes: %w[resume_reviews:write], status: "revoked",
                                                    purpose: "review: resume against Sales Engineer at Acme")
    event = AuditEvent.find_by!(target: review)
    expect(event).to have_attributes(actor: "agent:drafter", model_version: "claude-opus-5-5", reasoning: "Reviewed: #{written.summary}")
    expect(event.changes_made.to_json).not_to include("discovery", "Spanish")
  end

  it "writes in the language asked" do
    ready
    _, worker = write(reviewed("language" => "Portuguese"), language: " Portuguese ")

    expect(worker.asked[:targets].sole).to include(language: "Portuguese")
    expect(application.resume_reviews.sole.language).to eq("Portuguese")
  end

  it "keeps what a failed call cost and writes no review; writes nothing for a broken result or a stopped run" do
    ready

    failed, = write(reviewed("outcome" => "error", "reason" => "llm_refusal", "llm" => llm("cost_usd" => 0.01)))
    expect(failed).to have_attributes(finished?: false, cost_usd: 0.01, summary: "The AI could not write it (llm_refusal).")

    broken, = write(reviewed("strengths" => [ { "point" => "x", "lines" => [ { "line" => "3" } ] } ]))
    expect(broken.summary).to eq("Not recorded: strength 1 must say its point and its lines with their text.")

    stopped, = write(stopped: "API credit exhausted")
    expect(stopped.summary).to eq("Stopped before it was written: API credit exhausted.")
    expect([ ResumeReview.count, LlmCall.where(purpose: "review").sum(:cost_usd) ]).to eq([ 0, 0.01 ])
  end

  it "refuses before any run without a resume and a description, and says so" do
    expect(described_class.refusal(application)).to eq("reviewing needs a resume, saved on the Profile page and the role's " \
                                                       "description, read on its page first")
    expect { write(reviewed) }.to raise_error(ArgumentError, /reviewing needs a resume/)
    expect(AgentCredential.count).to eq(0)
  end

  it "holds no more than a review run needs: its credential can't write a draft, nor a call for one" do
    resume, description = ready

    expect do
      as_agent("agent:drafter", scopes: %w[resume_reviews:write]) do
        application.drafts.create!(kind: "cover_letter", language: "English", body: "x", written_body: "x", resume: resume,
                                   resume_hash: resume.content_hash, role_description: description,
                                   description_hash: description.content_hash, run_id: "r")
      end
    end.to raise_error(Authority::Denied, /may not create a draft/)
    expect { as_agent("agent:drafter", scopes: %w[resume_reviews:write]) { create(:llm_call, purpose: "draft", page_check: nil) } }
      .to raise_error(Authority::Denied, /may not create a llm call/)
  end

  it "costs what reviews have cost on the record, and a guess before the first" do
    expect(described_class.estimate).to eq(ResumeReviews::FIRST_ESTIMATE)
    ready
    write(reviewed)
    expect(described_class.estimate).to eq(0.056)
  end
end
