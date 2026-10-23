require "rails_helper"
require Rails.root.join("mcp/provenance_mcp")
ProvenanceMcp.tools
ProvenanceMcp.prompts

# What the operator's own Claude client saves back through MCP (2d step 3): as agent:assistant, under a credential
# for that one call, read against the resume version it saw. Save tools write, so examples may write after a call.
RSpec.describe "Saving what the client wrote, through MCP" do
  let!(:company) { create(:company, :resolved, name: "Acme", domain: "acme.example") }
  let!(:role) { create(:posting, :verified_live, company: company, role_title: "Sales Engineer") }
  let!(:application) { create(:application, posting: role) }
  let!(:profile) { SearchProfile.create!(titles: [ "Sales Engineer" ]) }
  let!(:resume) { Resumes.keep!(profile, text: "Jordan Sample\nSales engineer, eight years.\n- Ran discovery for 35 accounts a year.") }
  let!(:description) do
    role.role_descriptions.create!(text: "Discovery. Spanish required.", content_hash: Resume.digest("Discovery. Spanish required."),
                                   read_via: "render", url: "https://acme.example/jobs/1", run_id: "r1", first_read_at: 1.day.ago,
                                   last_read_at: 1.day.ago)
  end

  def save(tool, **arguments) = ProvenanceMcp::Tools.const_get(tool).call(**arguments, server_context: nil)

  def said(response) = response.content.sole[:text]

  def letter(**fields)
    { application: "acme sales", kind: "cover_letter", resume_version: resume.version, language: "English",
      body: "Dear Acme team,\n\nI ran discovery for 35 accounts a year.\n\nJordan Sample",
      lines_drawn_on: [ { line: 3, answers: "discovery" }, { line: 9, answers: "a line it lacks" } ],
      gaps: [ { asks: "Spanish", note: "Not shown." } ], note: "Leads with discovery.", model: "claude-opus-5-5" }.merge(fields)
  end

  describe "save_draft" do
    it "saves a letter as the assistant's, under a credential for that call, its lines read against the resume version it saw" do
      response = save(:SaveDraft, **letter)

      draft = application.drafts.sole
      expect(response.error?).to be(false)
      expect(said(response)).to start_with("Saved for Acme / Sales Engineer: Cover letter in English: 13 words, drawing on 1 line of the " \
                                           "resume, 1 gap flagged; 1 line it named isn't in the resume, left out.")
      expect(said(response)).to include("Draft id #{draft.id}", "/applications/#{application.id}#drafts", "nothing is sent")
      expect(draft).to have_attributes(kind: "cover_letter", status: "draft", written_by: "agent:assistant", reported_model: "claude-opus-5-5",
                                       resume: resume, role_description: description, llm_call: nil, dropped_lines: 1, edited?: false,
                                       notes: "Leads with discovery.")
      expect(draft.drew_on).to eq([ { "line" => 3, "text" => "- Ran discovery for 35 accounts a year.", "used_for" => "discovery" } ])
      expect(draft.gaps).to eq([ { "asks" => "Spanish", "note" => "Not shown." } ])

      credential = AgentCredential.sole
      expect(credential).to have_attributes(actor: "agent:assistant", scopes: %w[drafts:write], purpose: "mcp: save_draft", status: "revoked")
      expect(draft.run_id).to eq("mcp:#{credential.id}")
      event = AuditEvent.find_by!(target: draft)
      expect(event).to have_attributes(actor: "agent:assistant", credential: credential, reasoning: start_with("Saved through MCP: Cover letter"))
      expect(event.changes_made.to_json).not_to include("discovery", "Jordan")
    end

    it "saves a polished version as a new draft that revises the one before, which stays" do
      save(:SaveDraft, **letter)
      first = application.drafts.sole

      response = save(:SaveDraft, **letter(body: "Dear Acme team,\n\nShorter.\n\nJordan Sample", revises: first.id))

      expect(said(response)).to include("; it revises the cover letter of #{first.created_at.utc.to_date}.")
      expect(application.drafts.newest_first.first).to have_attributes(revises: first)
      expect(application.drafts.count).to eq(2)
    end

    it "saves an outreach note with its subject, and a tailored resume with its changes by line" do
      save(:SaveDraft, **letter(kind: "outreach_note", subject: " Sales Engineer, Acme ", body: "Hi [name], ..."))
      save(:SaveDraft, **letter(kind: "tailored_resume", body: "Jordan Sample\n- Ran discovery for 35 accounts a year.\nSales engineer.",
                                lines_drawn_on: [], changes: [ { change: "Discovery first", lines: [ 3, 2 ] }, { change: "", lines: [ 1 ] } ]))

      note = application.drafts.find_by!(kind: "outreach")
      tailored = application.drafts.find_by!(kind: "tailored_resume")
      expect(note).to have_attributes(subject: "Sales Engineer, Acme", written_subject: "Sales Engineer, Acme")
      expect(tailored).to have_attributes(drew_on: [], label: "Tailored resume")
      expect(tailored.tailoring).to eq([ { "change" => "Discovery first", "lines" => [ { "line" => 3, "text" => "- Ran discovery for 35 accounts a year." },
                                                                                     { "line" => 2, "text" => "Sales engineer, eight years." } ] } ])
    end

    it "saves an outreach note to the contact it names, at the application's company, and says whom it is to" do
      ana = Contacts.save!(company, { name: "Ana Lima", kind: "recruiter" })

      response = save(:SaveDraft, **letter(kind: "outreach_note", subject: "Sales Engineer", body: "Hi Ana, ...", contact: " ana lima "))

      draft = application.drafts.sole
      expect(said(response)).to start_with("Saved for Acme / Sales Engineer, to Ana Lima: Outreach note in English")
      expect(draft.contact).to eq(ana)
      event = AuditEvent.find_by!(target: draft)
      expect(event.changes_made).to include("contact_id" => [ nil, ana.id ])
      expect(event.reasoning).not_to include("Ana")

      expect(said(save(:SaveDraft, **letter(contact: ana.id)))).to eq("Not saved: only an outreach note is addressed to someone.")
      expect(said(save(:SaveDraft, **letter(kind: "outreach_note", contact: "Bea")))).to start_with('No contact named "Bea" at Acme.')
      expect(application.drafts.count).to eq(1)

      expect(said(save(:GetDraft, draft: draft.id))).to start_with("Outreach note for Acme / Sales Engineer, to Ana Lima (contact id #{ana.id}), in English: a draft.")
      expect(ProvenanceMcp::Writing.written(application)).to include("- Outreach note to Ana Lima in English, 3 words, a draft")
    end

    it "saves nothing it can't read straight, and says why" do
      expect(said(save(:SaveDraft, **letter(resume_version: "0123456789ab")))).to start_with('Not saved: resume version "0123456789ab" isn\'t on record')
      expect(said(save(:SaveDraft, **letter(revises: SecureRandom.uuid)))).to start_with("Not saved: it revises no draft of this application")
      expect(said(save(:SaveDraft, **letter(body: "  ")))).to eq("Not saved: the text is empty.")
      expect(said(save(:SaveDraft, **letter(application: "globex")))).to start_with('No application matches "globex"')

      description.destroy!
      expect(said(save(:SaveDraft, **letter))).to eq("Not saved: the role's description isn't read yet: it is read from the role's page in the app.")
      expect(Draft.count).to eq(0)
    end

    it "is the operator's to edit, approve, and delete; the assistant may only save a new one" do
      save(:SaveDraft, **letter)
      draft = application.drafts.sole

      expect { as_agent("agent:assistant") { draft.update!(status: "approved", approved_at: Time.current) } }
        .to raise_error(Authority::Denied, /may not update a draft/)
      expect(Drafts.approve!(draft.reload)).to have_attributes(approved?: true)
    end
  end

  describe "save_resume_review" do
    def review(**fields)
      { application: application.id, resume_version: resume.version, language: "English",
        strengths: [ { point: "Discovery at volume", lines: [ 3 ] } ], gaps: [ { asks: "Spanish", note: "Not shown." } ],
        suggestions: [ { change: "Lead with discovery", lines: [ 3, 1, 40 ] } ], note: "A close fit.", model: "claude-opus-5-5" }.merge(fields)
    end

    it "saves a review as the assistant's, its lines read against the resume version it saw, audited by its counts" do
      response = save(:SaveResumeReview, **review)

      saved = application.resume_reviews.sole
      expect(said(response)).to start_with("Saved for Acme / Sales Engineer: Resume review in English: 1 strength, 1 gap, 1 suggestion; " \
                                           "1 line it named isn't in the resume, left out.")
      expect(saved).to have_attributes(written_by: "agent:assistant", resume: resume, role_description: description, note: "A close fit.",
                                       reported_model: "claude-opus-5-5", dropped_lines: 1)
      expect(saved.suggestions.sole["lines"].pluck("line")).to eq([ 3, 1 ])
      expect(AgentCredential.sole).to have_attributes(scopes: %w[resume_reviews:write], purpose: "mcp: save_resume_review", status: "revoked")
      event = AuditEvent.find_by!(target: saved)
      expect(event.changes_made).to include("strengths" => [ nil, 1 ], "suggestions" => [ nil, 1 ])
      expect(event.changes_made.to_json).not_to include("Discovery", "Spanish")
    end

    it "says nothing it can't: an empty review is not saved" do
      expect(said(save(:SaveResumeReview, **review(strengths: [], gaps: [], suggestions: []))))
        .to eq("Not saved: a review says something: its strengths, gaps, or suggestions.")
    end

    it "is deleted by the operator alone, its record keeping its counts" do
      save(:SaveResumeReview, **review)
      saved = application.resume_reviews.sole

      expect { as_agent("agent:assistant") { saved.destroy! } }.to raise_error(Authority::Denied, /may not destroy a resume review/)
      ResumeReviews.delete!(saved.reload)
      expect(ResumeReview.count).to eq(0)
      expect(AuditEvent.where(target_type: "ResumeReview", action: "destroy").sole.changes_made).to include("gaps" => [ 1, nil ])
    end
  end

  it "tells the client what the save tools are for, and the prompts how to save" do
    expect(ProvenanceMcp::INSTRUCTIONS).to include("use them only when", "nothing is ever sent")
    expect(ProvenanceMcp::Writing.instructions("cover_letter")).to include("When I say to save it, save it with save_draft (kind cover_letter)")
    expect(ProvenanceMcp::Writing.instructions("resume_review")).to include("save_resume_review")
    expect(ProvenanceMcp::Tools::SaveDraft.to_h[:annotations]).to include(readOnlyHint: false, destructiveHint: false)
  end
end
