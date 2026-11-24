require "rails_helper"

# A role's page (4e step 2): its header (its listing, its fits, and what you can do), its overview always in view, then
# tabs with its fit first; its history holds what was saved under it, a fit score the AI assistant weighed included.
RSpec.describe "A role's page", type: :request do
  let!(:company) { create(:company, :resolved, name: "Acme", domain: "acme.example") }
  let!(:profile) { SearchProfile.create!(titles: [ "Solutions Engineer" ]) }
  let!(:resume) { Resumes.keep!(profile, text: "Jordan Sample\nSolutions engineer.\n- Ran discovery for 35 accounts a year.") }
  let!(:role) { create(:posting, :verified_live, company: company, role_title: "Solutions Engineer", tracking: "tracked") }

  def weigh!
    text = "You will run discovery."
    description = role.role_descriptions.create!(text: text, content_hash: Resume.digest(text), read_via: "render", run_id: "r1",
                                                  url: "https://acme.example/jobs/1", first_read_at: 1.day.ago, last_read_at: 1.day.ago)
    Authority.unchecked do # history, as the AI assistant wrote it through MCP
      score = role.fit_scores.create!(score: 64, why: "Discovery shown.", resume: resume, resume_hash: resume.content_hash,
                                      role_description: description, description_hash: description.content_hash,
                                      written_by: "agent:assistant", gaps: [ { "asks" => "Rails", "note" => "Not on the resume." } ])
      AuditEvent.record!(actor: "agent:assistant", action: "create", target: score, reasoning: "Saved through MCP: 64.",
                         changes_made: { "score" => [ nil, 64 ], "gaps" => [ nil, 1 ] })
    end
  end

  it "opens on its fit, with its listing, its fits and its actions in the header, and its overview in view" do
    weigh!
    get role_path(role)

    body = response.body
    expect(body).to include(">Listing</dt>", "Still listed", "ATS fit", "Company fit", "Check now", "Archive", "Start an application")
    expect(body).to include(%(id="fit-tab" role="tab" aria-controls="fit" aria-selected="true"),
                            %(id="checks-tab" role="tab" aria-controls="checks" aria-selected="false"))
    expect(body).to match(/<section id="fit" class="tab-panel"[^>]*data-tabs-target="panel">/)
                .and match(/<section id="checks" class="tab-panel"[^>]*hidden="hidden"/)
    expect(body.index(">Listing</dt>")).to be < body.index(%(role="tablist"))
    expect(body.index("<h3>ATS fit</h3>")).to be < body.index("What it asks that your resume doesn't show")
  end

  it "keeps in its history the fit score the AI assistant saved, beside the role's own changes" do
    weigh!
    get role_path(role)

    expect(response.body).to include("fit weighed: 64", "Saved through MCP: 64.")
  end

  it "says Listing, not Answer, on the Roles list" do
    get roles_path
    expect(response.body).to include("<th>Listing</th>", %(aria-label="Filter by listing")).and not_include("<th>Answer</th>")
  end
end
