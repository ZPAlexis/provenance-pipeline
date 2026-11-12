require "rails_helper"
require Rails.root.join("mcp/provenance_mcp")
ProvenanceMcp.tools
ProvenanceMcp.prompts

# Cover letters and outreach notes with what the operator is looking for, through MCP (4c step 4): given that part
# alone, for motivation, never a claim of experience; every claim still traces to a resume line, so a background line
# cited anywhere in a letter or a note is refused. A read tool's or a prompt's call leaves the test's transaction
# read-only: each example writes before its first such call.
RSpec.describe "Cover letters and outreach notes with what the operator is looking for, through MCP" do
  let!(:company) { create(:company, :resolved, name: "Acme", domain: "acme.example") }
  let!(:role) { create(:posting, :verified_live, company: company, role_title: "Sales Engineer") }
  let!(:application) { create(:application, posting: role) }
  let!(:profile) { SearchProfile.create!(titles: [ "Sales Engineer" ]) }
  let!(:resume) { Resumes.keep!(profile, text: "Jordan Sample\nSales engineer, eight years.\n- Ran discovery for 35 accounts a year.") }
  let!(:description) do
    text = "Discovery with revenue teams."
    role.role_descriptions.create!(text: text, content_hash: Resume.digest(text), read_via: "render", url: "https://acme.example/jobs/1",
                                   run_id: "r1", first_read_at: 1.day.ago, last_read_at: 1.day.ago)
  end
  # B1 is what they're looking for, B2 a role preference, B3 background not on the resume.
  let!(:background) do
    later do
      Backgrounds.keep!(profile, looking_for: "A long-term role building revenue systems.", role_preferences: "Internal-facing work first.",
                                 not_on_resume: "Set up a first Salesforce sales-operations process.")
    end
  end

  def call(tool, **arguments) = ProvenanceMcp::Tools.const_get(tool).call(**arguments, server_context: nil)

  def said(response) = response.content.sole[:text]

  def prompt(kind) = ProvenanceMcp.server.prompts.fetch(kind).template({ application: "acme sales" }).messages.sole.to_h.dig(:content, :text)

  def letter(kind: "cover_letter", **given)
    call(:SaveDraft, application: "acme sales", kind: kind, resume_version: resume.version, language: "English",
                     body: "Dear Acme team,\n\nI ran discovery for 35 accounts a year, and I'm looking to build revenue systems.\n\nJordan Sample",
                     lines_drawn_on: [ { line: 3, answers: "discovery" } ], background_version: background.version, **given)
  end

  it "gives a letter or a note what the operator is looking for alone, as motivation, with its rules" do
    materials = said(call(:ApplicationMaterials, application: "acme sales", kind: "outreach_note"))

    expect(materials).to include("What I'm looking for, the operator's own word (their motivation only, never a claim of experience; cite none of its lines)",
                                 "<background part=\"looking_for\" version=\"#{background.version}\">\n[B1] A long-term role building revenue systems.\n</background>")
    expect(materials).not_to include("Internal-facing", "Salesforce")

    letter_prompt = prompt("cover_letter")
    expect(letter_prompt).to include(ProvenanceMcp::Writing.rules["background_letter"], "give the background version from the materials",
                                     "Cite no background line in lines_drawn_on", "[B1] A long-term role")
    expect(letter_prompt).not_to include(ProvenanceMcp::Writing.rules["background_resume"], "Salesforce")
    expect(prompt("resume_review")).not_to include(ProvenanceMcp::Writing.rules["background_letter"])
  end

  it "saves a letter that read it, recording that part's hash; refuses one citing a background line, however it is named" do
    text = said(letter)

    draft = application.drafts.sole
    expect(text).to include("Cover letter in English:", "drawing on 1 line of the resume", "it read what you're looking for, for motivation")
    expect(draft).to have_attributes(background: background, background_hash: background.hash_of("looking_for"),
                                     drew_on: [ include("line" => 3) ])
    expect(AuditEvent.find_by!(target: draft).changes_made).to include("background_hash" => [ nil, background.hash_of("looking_for") ])

    refused = "Not saved: a cover letter or an outreach note cites no line of the background: what the operator is looking for is " \
              "their motivation, never a claim, and every claim traces to a line of the resume."
    expect(said(letter(lines_drawn_on: [ { line: "B1", answers: "motivation" } ]))).to eq(refused)
    expect(said(letter(kind: "outreach_note", changes: [ { change: "x", lines: [], background_lines: [ "B3" ] } ]))).to eq(refused)
    expect(application.drafts.count).to eq(1)
  end

  it "goes stale only when what they're looking for changes" do
    letter
    draft = application.drafts.sole

    later { Backgrounds.keep!(profile, looking_for: "A long-term role building revenue systems.", not_on_resume: "Something else.") }
    expect(draft.background_stale_for(Backgrounds.newest(profile))).to be(false)
    later { Backgrounds.keep!(profile, looking_for: "Growing into a Lead role.") }
    expect(said(call(:GetDraft, draft: draft.id))).to include("Changed since it was written: the background it read.")
  end
end
