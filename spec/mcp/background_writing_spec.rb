require "rails_helper"
require Rails.root.join("mcp/provenance_mcp")
ProvenanceMcp.tools
ProvenanceMcp.prompts

# Resume reviews and tailored resumes with the background, through MCP (4c step 3): given the kind of writing, the
# client reads the part of the background that kind may use (background not on the resume), and whatever it draws from
# it cites its lines, flagged "from your background, not on the resume" for the operator to confirm. A read tool's or a
# prompt's call leaves the test's transaction read-only: each example writes before its first such call.
RSpec.describe "Resume reviews and tailored resumes with the background, through MCP" do
  let!(:company) { create(:company, :resolved, name: "Acme", domain: "acme.example") }
  let!(:role) { create(:posting, :verified_live, company: company, role_title: "Sales Engineer") }
  let!(:application) { create(:application, posting: role) }
  let!(:profile) { SearchProfile.create!(titles: [ "Sales Engineer" ]) }
  let!(:resume) { Resumes.keep!(profile, text: "Jordan Sample\nSales engineer, eight years.\n- Ran discovery for 35 accounts a year.") }
  let!(:description) do
    text = "Discovery. Salesforce administration a must."
    role.role_descriptions.create!(text: text, content_hash: Resume.digest(text), read_via: "render", url: "https://acme.example/jobs/1",
                                   run_id: "r1", first_read_at: 1.day.ago, last_read_at: 1.day.ago)
  end
  # B1 is what they're looking for, B2 a role preference, B3 and B4 the background not on the resume.
  let!(:background) do
    later do
      Backgrounds.keep!(profile, looking_for: "A long-term role building revenue systems.", role_preferences: "Internal-facing work first.",
                                 not_on_resume: "Set up a first Salesforce sales-operations process.\nPortuguese, native.")
    end
  end

  def call(tool, **arguments) = ProvenanceMcp::Tools.const_get(tool).call(**arguments, server_context: nil)

  def said(response) = response.content.sole[:text]

  def prompt(kind) = ProvenanceMcp.server.prompts.fetch(kind).template({ application: "acme sales" }).messages.sole.to_h.dig(:content, :text)

  def review(**given)
    call(:SaveResumeReview, application: "acme sales", resume_version: resume.version, language: "English", background_version: background.version,
                            strengths: [ { point: "Discovery", lines: [ 3 ] },
                                         { point: "A Salesforce sales-operations process", lines: [], background_lines: [ "B3", "B2" ] } ],
                            suggestions: [ { change: "Add the Salesforce process you set up", lines: [ 2 ], background_lines: [ 3 ] } ],
                            gaps: [ { asks: "Salesforce administration", note: "Not on the resume." } ], model: "claude-opus-5-5", **given)
  end

  it "gives a resume review or a tailored resume the background not on the resume, numbered as the whole's, and no other part" do
    materials = said(call(:ApplicationMaterials, application: "acme sales", kind: "resume_review"))

    expect(materials).to include("Background not on the resume, the operator's own word",
                                 "<background part=\"not_on_resume\" version=\"#{background.version}\">\n" \
                                 "[B3] Set up a first Salesforce sales-operations process.\n[B4] Portuguese, native.\n</background>")
    expect(materials).not_to include("Internal-facing", "A long-term role")
    expect(said(call(:ApplicationMaterials, application: "acme sales"))).not_to include("<background")
    expect(said(call(:ApplicationMaterials, application: "acme sales", kind: "cover_letter"))).not_to include("<background")

    expect(prompt("tailored_resume")).to include(ProvenanceMcp::Writing.rules["background_resume"], "background_lines", "[B3] Set up")
    expect(prompt("resume_review")).to include("from your background, not on the resume")
    expect(prompt("cover_letter")).not_to include("background_resume", "<background")
    expect(said(call(:WritingRules, kind: "resume_review"))).to include(ProvenanceMcp::Writing.rules["background_resume"])
  end

  it "saves a review's points drawn from the background, flagged, citing only lines of the part it may read" do
    text = said(review)

    saved = application.resume_reviews.sole
    expect(text).to start_with("Saved for Acme / Sales Engineer: Resume review in English: 2 strengths, 1 gap, 1 suggestion; 2 drawn from " \
                               "your background, not on the resume, for you to confirm; 1 line it named isn't in the resume, left out.")
    expect(saved.strengths.last).to eq("point" => "A Salesforce sales-operations process", "lines" => [],
                                       "background_lines" => [ { "line" => 3, "text" => "Set up a first Salesforce sales-operations process.",
                                                                 "part" => "not_on_resume" } ])
    expect(saved.strengths.first).not_to have_key("background_lines")
    expect(saved).to have_attributes(background: background, background_hash: background.hash_of("not_on_resume"), dropped_lines: 1)
    event = AuditEvent.find_by!(target: saved)
    expect(event.changes_made).to include("from_background" => [ nil, 2 ], "background_hash" => [ nil, background.hash_of("not_on_resume") ])
    expect(event.changes_made.to_json).not_to include("Salesforce", "Portuguese")

    expect(said(review(background_version: nil))).to eq("Not saved: give the background version you read: its lines are cited against it.")
    expect(said(review(background_version: "0123456789ab"))).to start_with("Not saved: background version \"0123456789ab\" isn't on record")
  end

  it "saves a tailored resume's changes drawn from the background, flagged; and a letter reads none of it yet" do
    text = said(call(:SaveDraft, application: "acme sales", kind: "tailored_resume", resume_version: resume.version, language: "English",
                                 body: "Jordan Sample\nSales engineer, eight years.\nSet up a first Salesforce sales-operations process.",
                                 background_version: background.version,
                                 changes: [ { change: "Moved discovery up", lines: [ 3 ] }, { change: "Added the Salesforce process", lines: [], background_lines: [ "B3" ] } ]))

    draft = application.drafts.sole
    expect(text).to include("Tailored resume in English: 13 words, 2 changes (1 drawn from your background, not on the resume, for you to confirm)")
    expect(draft.from_background(draft.tailoring).sole["background_lines"].map { |line| line["line"] }).to eq([ 3 ])
    expect(draft.background_hash).to eq(background.hash_of("not_on_resume"))
    expect(said(call(:SaveDraft, application: "acme sales", kind: "cover_letter", resume_version: resume.version, language: "English",
                                 body: "Dear Acme team.", background_version: background.version)))
      .to eq("Not saved: this kind of writing reads no part of the background.")

    shown = said(call(:GetDraft, draft: draft.id))
    expect(shown).to include("- Added the Salesforce process [lines ] [from the background, not on the resume, to confirm: B3]",
                             "What it was written from is as it was when it was written.")
  end

  it "says when the part a draft read has changed since, and only that part" do
    call(:SaveDraft, application: "acme sales", kind: "tailored_resume", resume_version: resume.version, language: "English", body: "Jordan Sample.",
                     background_version: background.version, changes: [ { change: "Added it", lines: [], background_lines: [ "B3" ] } ])
    draft = application.drafts.sole
    later { Backgrounds.keep!(profile, looking_for: "Something else.", role_preferences: "Internal-facing work first.",
                                       not_on_resume: "Set up a first Salesforce sales-operations process.\nPortuguese, native.") }
    expect(draft.background_stale_for(Backgrounds.newest(profile))).to be(false) # another part changed

    later { Backgrounds.keep!(profile, not_on_resume: "Portuguese, native.") }
    expect(said(call(:GetDraft, draft: draft.id))).to include("Changed since it was written: the background it read.")
  end
end
