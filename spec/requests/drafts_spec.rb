require "rails_helper"

RSpec.describe "Drafts", type: :request do
  include ActiveJob::TestHelper

  let!(:company) { create(:company, :resolved, name: "Acme", domain: "acme.example") }
  let!(:role) { create(:posting, company: company, role_title: "Sales Engineer", tracking: "tracked", job_url: "https://acme.example/jobs/1") }
  let!(:application) { create(:application, posting: role) }
  let!(:profile) { SearchProfile.create!(titles: [ "Sales Engineer" ]) }

  def body_text = "Dear Acme hiring team,\n\nI ran technical discovery for 40 accounts.\n\nAlex Example"

  def ready
    resume = Resumes.keep!(profile, text: "Alex Example\nRan technical discovery for 40 accounts.")
    description = role.role_descriptions.create!(text: "Discovery. Spanish required.", content_hash: Resume.digest("Discovery. Spanish required."),
                                                 read_via: "render", url: role.job_url, run_id: "r1", first_read_at: 1.day.ago,
                                                 last_read_at: 1.day.ago)
    [ resume, description ]
  end

  # A draft as the drafter leaves one, its call and its event included.
  def drafted(kind: "cover_letter", subject: nil, **fields)
    resume, description = ready
    call = LlmCall.create!(run_id: "20261019T120000Z-draft", purpose: "draft", model: "claude-opus-5-5",
                           settings: { "output_config" => { "effort" => "medium" } }, prompt_version: "c24d8ab8151c",
                           input_tokens: 2_386, output_tokens: 2_667, cost_usd: 0.063, called_at: Time.current)
    application.drafts.create!(kind: kind, language: "English", subject: subject, body: body_text, written_subject: subject,
                               written_body: body_text, resume: resume, resume_hash: resume.content_hash, role_description: description,
                               description_hash: description.content_hash, llm_call: call,
                               run_id: call.run_id, notes: "It leads with discovery.",
                               drew_on: [ { "line" => 2, "text" => "Ran technical discovery for 40 accounts.", "used_for" => "discovery" } ],
                               gaps: [ { "asks" => "Spanish", "note" => "Your resume shows none." } ], **fields)
  end

  def draft_events = AuditEvent.where(target_type: "Draft").order(:occurred_at)

  it "says what drafting needs until a resume and the role's description are on record" do
    get application_path(application)

    expect(response.body).to include("Drafting needs a resume, saved on the Profile page and the role&#39;s description, read on its page first")
    expect(response.body).not_to include("Write it")
  end

  it "offers a draft once they are, with what it costs, and queues it in the background as asked, one at a time" do
    ready
    get application_path(application)
    expect(response.body).to include("Write it", "Anything to stress", "about $0.070", "nothing is ever sent")

    expect do
      post application_drafts_path(application), params: { kind: "outreach", language: " Portuguese ", guidance: "Discovery." }
    end.to have_enqueued_job(CheckNowJob)
    expect(CheckRun.sole).to have_attributes(kind: "draft", posting: role, company: company, ceiling_usd: 0.07,
                                             request: { "kind" => "outreach", "language" => "Portuguese", "guidance" => "Discovery.",
                                                        "contact_id" => nil })

    post application_drafts_path(application), params: { kind: "cover_letter" }
    expect(CheckRun.count).to eq(1)

    get application_path(application)
    expect(response.body).to include("Waiting for the check before it to finish").and(not_include("Write it"))

    get root_path
    expect(response.body).to include("(an outreach note)", "/applications/#{application.id}#drafts")
  end

  it "addresses an outreach note to one of the company's contacts, as asked, and to no one at another company" do
    ready
    get application_path(application)
    expect(response.body).not_to include("draft_contact") # no contacts yet

    ana = Contacts.save!(company, { name: "Ana Lima", role: "Technical Recruiter", kind: "recruiter" })
    bea = Contacts.save!(create(:company, :resolved, name: "Globex", domain: "globex.example"), { name: "Bea Souza" })
    get application_path(application)
    expect(response.body).to include("draft_contact", "Ana Lima (Technical Recruiter)", "No one named: &quot;Hi [name],&quot;")
                         .and(not_include("Bea Souza"))

    post application_drafts_path(application), params: { kind: "cover_letter", contact_id: ana.id }
    expect(flash[:alert]).to eq("Not written: only an outreach note is addressed to someone.")
    post application_drafts_path(application), params: { kind: "outreach", contact_id: bea.id }
    expect(flash[:alert]).to eq("The record you were looking for could not be found.")
    expect(CheckRun.count).to eq(0)

    post application_drafts_path(application), params: { kind: "outreach", contact_id: ana.id }
    expect(CheckRun.sole.request).to include("kind" => "outreach", "contact_id" => ana.id)
  end

  it "says whom an outreach note is to, and keeps the note when they are deleted" do
    ana = Contacts.save!(company, { name: "Ana Lima", kind: "recruiter" })
    draft = drafted(kind: "outreach", subject: "Sales Engineer at Acme", contact: ana)

    get application_path(application)
    expect(response.body).to include("to Ana Lima · English")

    Contacts.delete!(ana)
    expect(draft.reload).to have_attributes(contact: nil, body: body_text)
    expect(AuditEvent.find_by!(target_type: "Contact", action: "destroy").reasoning)
      .to end_with("1 outreach note addressed to them is now to no one on record.")
  end

  it "refuses what it can't write before anything is queued" do
    ready

    post application_drafts_path(application), params: { kind: "thank_you" }
    expect(flash[:alert]).to eq('Not written: unknown kind of draft "thank_you".')

    post application_drafts_path(application), params: { kind: "cover_letter", guidance: "x" * 501 }
    expect(flash[:alert]).to eq("Not written: what to stress fits in 500 characters.")
    expect(CheckRun.count).to eq(0)
  end

  it "shows each draft with its gaps, what it drew on, and what it was written from and by" do
    draft = drafted(kind: "outreach", subject: "Sales Engineer at Acme", asked_language: "English", guidance: "Discovery.")

    get application_path(application)

    expect(response.body).to include("1 draft", "Outreach note", "Sales Engineer at Acme", "I ran technical discovery for 40 accounts.",
                                     "Save and approve", "Copy subject", "Copy note", "Delete",
                                     "What the role asks for that your resume doesn't show", "Spanish", "Your resume shows none.",
                                     "It leads with discovery.", "[2]", "claude-opus-5-5 at medium effort for $0.063",
                                     "You asked for English and to stress “Discovery.”", "draft_#{draft.id}")
    expect(response.body).not_to include("changed since it was written", "“Discovery.”.")

    Resumes.keep!(profile, text: "Alex Example\nA newer resume.")
    get application_path(application)
    expect(response.body).to include("Your resume has changed since it was written")
  end

  it "saves the operator's edits, and approves on 'Save and approve', each audited by size and hash" do
    draft = drafted

    patch application_draft_path(application, draft), params: { body: "#{body_text}\n\nP.S. From November.", approve: "1" }
    expect(flash[:notice]).to eq("Cover letter saved and approved. Copy it and send it yourself: nothing is sent from here.")
    expect(draft.reload).to have_attributes(approved?: true, edited?: true, body: "#{body_text}\n\nP.S. From November.")

    get application_path(application)
    expect(response.body).to include("Approved", "1 draft, 1 approved", "edited by you").and(not_include("Save and approve"))

    patch application_draft_path(application, draft), params: { body: "Shorter." }
    expect(flash[:notice]).to eq("Cover letter saved. It was approved: it is a draft again.")
    expect(draft.reload.status).to eq("draft")

    patch application_draft_path(application, draft), params: { body: "Shorter." }
    expect(flash[:notice]).to eq("Nothing to save: it says the same as before.")

    patch application_draft_path(application, draft), params: { body: "Shorter.", approve: "1" }
    expect(flash[:notice]).to eq("Cover letter approved. Copy it and send it yourself: nothing is sent from here.")

    expect(draft_events.pluck(:actor).uniq).to eq([ "human:operator" ])
    expect(draft_events.map { |event| event.changes_made.to_json }.join).not_to include("November", "Shorter")
  end

  it "refuses an empty text, and deletes a draft, its record naming its size and hash" do
    draft = drafted

    patch application_draft_path(application, draft), params: { body: "  " }
    expect(flash[:alert]).to eq("Not saved: a draft needs its text: delete it instead.")

    delete application_draft_path(application, draft)
    expect(flash[:notice]).to eq("Cover letter deleted.")
    expect(Draft.count).to eq(0)
    expect(draft_events.sole).to have_attributes(action: "destroy", reasoning: "Cover letter deleted on its application's page.")
  end

  it "shows a draft run that wrote nothing, with why" do
    ready
    CheckRun.create!(kind: "draft", company: company, posting: role, requested_by: "human:operator", status: "failed", answer: "not drafted",
                     error: "The AI could not write it (llm_refusal).", finished_at: Time.current, request: { "kind" => "cover_letter" })

    get application_path(application)

    expect(response.body).to include("Didn't finish", "The AI could not write it (llm_refusal).", "Write it")
  end
end
