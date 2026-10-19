require "rails_helper"

RSpec.describe Drafts do
  let!(:company) { create(:company, :resolved, name: "Acme", domain: "acme.example") }
  let!(:role) do
    create(:posting, company: company, role_title: "Sales Engineer", location: "Remote - Brazil", tracking: "tracked",
                     job_url: "https://job-boards.greenhouse.io/acme/jobs/4012345")
  end
  let!(:application) { create(:application, posting: role, notes: "They care about discovery.") }
  let!(:profile) { SearchProfile.create!(titles: [ "Sales Engineer" ], places: [ "Brazil" ], work_modes: [ "remote" ]) }

  def resume_text = "Alex Example\nSales engineer, eight years.\n- Ran technical discovery for 40 accounts."

  def body = "Dear Acme hiring team,\n\nI ran technical discovery for 40 accounts.\n\nAlex Example"

  def keep_resume(text = resume_text) = Resumes.keep!(profile, text: text)

  def describe_role(text = "You will run technical discovery. Spanish required.", at: Time.utc(2026, 10, 18, 9))
    role.role_descriptions.create!(text: text, content_hash: Resume.digest(text), read_via: "ats_api:greenhouse", url: role.job_url,
                                   run_id: "20261018T090000Z-describe", first_read_at: at, last_read_at: at)
  end

  # Stands in for Verifier::Worker: keeps what it was asked, leaves a targets file as the real one does, and hands back the results given.
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
  let(:run_dir) { Rails.root.join("tmp/verifier/20261019T120000Z-draft-spec") }

  after { FileUtils.rm_rf(run_dir) }

  def llm(**fields)
    { "model" => "claude-opus-5-5", "settings" => { "output_config" => { "effort" => "medium" } }, "purpose" => "draft",
      "prompt_version" => "d1e2f3a4b5c6", "input_tokens" => 3_000, "output_tokens" => 2_500, "cost_usd" => 0.062, **fields }
  end

  def drafted(**fields)
    { "kind" => "draft", "target_id" => application.id, "draft_kind" => "cover_letter", "outcome" => "ok",
      "language" => "English", "subject" => nil, "body" => body,
      "drew_on" => [ { "line" => 3, "text" => "- Ran technical discovery for 40 accounts.", "used_for" => "technical discovery" } ],
      "gaps" => [ { "asks" => "Spanish", "note" => "The resume shows none." } ], "notes" => "It leads with discovery.",
      "dropped_lines" => 0, "llm" => llm, **fields }
  end

  def write(*results, kind: "cover_letter", stopped: nil, **options)
    worker = worker_class.new(results, run_dir, stopped: stopped)
    [ described_class.write!(application, kind: kind, worker: worker, **options), worker ]
  end

  def draft_events = AuditEvent.where(target_type: "Draft").order(:occurred_at)

  context "with a resume and a description on record" do
    let!(:resume) { keep_resume }
    let!(:description) { describe_role }

    it "writes a draft under the drafter's credential, from the newest resume and description, keeping the lines it drew on" do
      written, worker = write(drafted)

      target = worker.asked[:targets].sole
      expect(worker.asked[:command]).to eq("draft")
      expect(target).to include(id: application.id, kind: "cover_letter", label: "Acme / Sales Engineer", role_title: "Sales Engineer",
                                company: "Acme", location: "Remote - Brazil", resume: resume_text, notes: "They care about discovery.",
                                description: "You will run technical discovery. Spanish required.", titles: [ "Sales Engineer" ],
                                places: [ "Brazil" ], work_modes: [ "remote" ], guidance: nil, language: nil)
      expect(run_dir.join("targets.json")).not_to exist # it held the whole resume

      draft = application.drafts.sole
      expect(draft).to have_attributes(kind: "cover_letter", status: "draft", language: "English", asked_language: nil, body: body,
                                       written_body: body, resume: resume, resume_hash: resume.content_hash, role_description: description,
                                       description_hash: description.content_hash, run_id: "20261019T120000Z-draft-spec", edited?: false)
      expect(draft.drew_on.sole).to eq("line" => 3, "text" => "- Ran technical discovery for 40 accounts.", "used_for" => "technical discovery")
      expect(draft.llm_call).to have_attributes(purpose: "draft", model: "claude-opus-5-5", cost_usd: 0.062, page_check: nil)
      expect(written).to have_attributes(finished?: true, answer: "drafted", cost_usd: 0.062, run_id: "20261019T120000Z-draft-spec",
                                         summary: "Cover letter in English: 13 words, drawing on 1 line of the resume, 1 gap flagged.")

      credential = AgentCredential.sole
      expect(credential).to have_attributes(actor: "agent:drafter", scopes: %w[drafts:write], status: "revoked",
                                            purpose: "draft: cover letter for Sales Engineer at Acme")
      event = draft_events.sole
      expect(event).to have_attributes(actor: "agent:drafter", action: "create", credential: credential, model_version: "claude-opus-5-5",
                                       reasoning: "Drafted: #{written.summary}")
      expect(event.changes_made).to include("words" => [ nil, 13 ], "content_hash" => [ nil, draft.content_hash ],
                                            "resume_hash" => [ nil, resume.content_hash ])
      expect(event.changes_made.to_json).not_to include("discovery", "Alex")
    end

    it "asks for another language and anything to stress, as the operator says them" do
      _, worker = write(drafted("draft_kind" => "outreach", "language" => "Portuguese", "subject" => "Sales Engineer"),
                        kind: "outreach", language: " Portuguese ", guidance: "Stress the discovery work.")

      expect(worker.asked[:targets].sole).to include(kind: "outreach", language: "Portuguese", guidance: "Stress the discovery work.")
      expect(application.drafts.sole).to have_attributes(kind: "outreach", asked_language: "Portuguese", language: "Portuguese",
                                                         guidance: "Stress the discovery work.", subject: "Sales Engineer")
    end

    it "keeps what a failed call cost, writes no draft, and says why" do
      written, = write(drafted("outcome" => "error", "reason" => "llm_refusal", "body" => nil, "llm" => llm("cost_usd" => 0.01)))

      expect(written).to have_attributes(finished?: false, cost_usd: 0.01, summary: "The AI could not write it (llm_refusal).")
      expect(LlmCall.sole).to have_attributes(purpose: "draft", cost_usd: 0.01)
      expect(Draft.count).to eq(0)
    end

    it "writes nothing for a result that breaks the contract, or a run that stopped first" do
      broken, = write(drafted("body" => " ", "drew_on" => [ { "line" => 0, "text" => "x", "used_for" => "y" } ]))
      expect(broken.summary).to eq("Not recorded: body is missing; drew_on 1 must have a line number, its text, and what it answers.")

      stopped, = write(stopped: "API credit exhausted")
      expect(stopped.summary).to eq("Stopped before it was written: API credit exhausted.")
      expect([ Draft.count, LlmCall.count ]).to eq([ 0, 0 ])
    end

    it "says when the drafter named lines the resume doesn't have" do
      written, = write(drafted("dropped_lines" => 2, "gaps" => []))

      expect(written.summary).to eq("Cover letter in English: 13 words, drawing on 1 line of the resume, no gaps; " \
                                    "2 lines it named aren't in the resume, left out.")
    end

    it "refuses an unknown kind, a language that isn't one, and too much to stress, before any run" do
      expect { write(kind: "thank_you") }.to raise_error(ArgumentError, /unknown kind of draft "thank_you"/)
      expect { write(language: "x" * 41) }.to raise_error(ArgumentError, /a language is named in a few words/)
      expect { write(guidance: "x" * 501) }.to raise_error(ArgumentError, /fits in 500 characters/)
      expect(AgentCredential.count).to eq(0)
    end

    describe "the operator's part" do
      let!(:draft) { write(drafted).first.draft }

      it "edits it, audited by size and hash; the same text again changes nothing" do
        edited = described_class.edit!(draft, body: "#{body}\r\n\r\nP.S. Available from November.")

        expect(edited).to have_attributes(body: "#{body}\n\nP.S. Available from November.", written_body: body, edited?: true)
        expect(edited.edited_at).to be_present
        event = draft_events.last(1).sole
        expect(event).to have_attributes(actor: "human:operator", action: "update", credential: nil,
                                         reasoning: "Cover letter edited on its application's page: 17 words.")
        expect(event.changes_made.keys).to match_array(%w[words content_hash])
        expect(event.changes_made.to_json).not_to include("November")

        expect(described_class.edit!(draft.reload, body: edited.body)).to be_nil
        expect { described_class.edit!(draft, body: " ") }.to raise_error(ArgumentError, /delete it instead/)
      end

      it "approves it, and an edit after that returns it to a draft" do
        described_class.approve!(draft)
        expect(draft.reload).to have_attributes(approved?: true, approved_at: be_present)
        expect { described_class.approve!(draft) }.to raise_error(ArgumentError, "it is approved already")

        described_class.edit!(draft, body: "Shorter.")
        expect(draft.reload).to have_attributes(status: "draft", approved_at: nil)
        expect(draft_events.map(&:reasoning).last(2)).to eq([
          "Cover letter approved on its application's page: 13 words. Nothing is sent.",
          "Cover letter edited on its application's page: 1 word. It was approved: it is a draft again."
        ])
      end

      it "deletes it, its record naming its size and hash" do
        described_class.delete!(draft)

        expect(Draft.count).to eq(0)
        expect(draft_events.last(1).sole.changes_made).to include("words" => [ 13, nil ], "kind" => [ "cover_letter", nil ])
      end

      it "is never the drafter's: it may write only a new draft as written, and only its own calls" do
        expect { as_agent(Drafts::ACTOR) { draft.update!(status: "approved", approved_at: Time.current) } }
          .to raise_error(Authority::Denied, /may not update a draft \(approved_at, status\) with drafts:write/)
        expect { as_agent(Drafts::ACTOR) { draft.update!(body: "Changed.") } }.to raise_error(Authority::Denied, /may not update a draft/)
        expect { as_agent(Drafts::ACTOR) { draft.destroy! } }.to raise_error(Authority::Denied, /may not destroy a draft/)
        expect do
          as_agent(Drafts::ACTOR) { application.drafts.create!(draft.attributes.except("id").merge("status" => "approved")) }
        end.to raise_error(Authority::Denied, /may not create a draft/)
        expect { as_agent(Drafts::ACTOR) { create(:llm_call, purpose: "extract", page_check: nil) } }
          .to raise_error(Authority::Denied, /may not create a llm call \(.*purpose.*\) with drafts:write/)
        expect { as_agent(Drafts::ACTOR) { application.update!(stage: "offer") } }.to raise_error(Authority::Denied, /may not update an application/)
        expect(AuditEvent.denied.count).to eq(6)
      end
    end
  end

  it "says what drafting needs, and refuses before any run without it" do
    expect(described_class.missing(application)).to eq([ "a resume, saved on the Profile page", "the role's description, read on its page" ])
    expect { write(drafted) }.to raise_error(ArgumentError, "drafting needs a resume, saved on the Profile page and the role's " \
                                                            "description, read on its page first")

    keep_resume
    describe_role
    expect(described_class.missing(application)).to be_empty
    expect(AgentCredential.count).to eq(0)
  end

  it "drafts from the newest versions, and costs what drafts have cost on the record" do
    keep_resume("Old resume.")
    describe_role("Old description.", at: Time.utc(2026, 10, 1))
    newest = keep_resume
    describe_role
    expect(described_class.estimate).to eq(Drafts::FIRST_ESTIMATE)

    _, worker = write(drafted)
    expect(worker.asked[:targets].sole).to include(resume: newest.text, description: "You will run technical discovery. Spanish required.")
    expect(described_class.estimate).to eq(0.062)
  end
end
