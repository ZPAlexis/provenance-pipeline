require "rails_helper"
require Rails.root.join("mcp/provenance_mcp")
ProvenanceMcp.tools
ProvenanceMcp.prompts

# A role's fit read two ways through MCP (4c step 2): the ATS fit, the resume alone as a recruiter's screening system would
# read it, and, when the operator's background is saved, the Background fit beside it, read against the background
# version the client saw. A read tool's or a prompt's call leaves the test's transaction read-only: each example writes
# before its first such call.
RSpec.describe "A role's fit read two ways, through MCP" do
  let!(:company) { create(:company, :resolved, name: "Acme", domain: "acme.example") }
  let!(:profile) { SearchProfile.create!(titles: [ "Sales Engineer" ], places: [ "Brazil" ]) }
  let!(:resume) { Resumes.keep!(profile, text: "Jordan Sample\nSales engineer, eight years.\n- Ran discovery for 35 accounts a year.") }
  # Saved inside `later` as every version after it is, so the newest is the newest.
  let!(:background) do
    later do
      Backgrounds.keep!(profile, looking_for: "A long-term role building revenue systems.",
                                 role_preferences: "Internal-facing work first.\nClassic pre-sales demos fit less for now.",
                                 not_on_resume: "Portuguese, native; English, fluent.\nSet up a first Salesforce sales-operations process.")
    end
  end
  let!(:role) { create(:posting, company: company, role_title: "Customer Engineer", job_url: "https://acme.example/jobs/1") }

  before do
    text = "Run discovery with enterprise buyers. Salesforce administration a must. Live demos weekly."
    role.role_descriptions.create!(text: text, content_hash: Resume.digest(text), read_via: "render", url: role.job_url, run_id: "r1",
                                   first_read_at: Time.utc(2026, 11, 10, 9), last_read_at: Time.utc(2026, 11, 10, 9))
  end

  def call(tool, **arguments) = ProvenanceMcp::Tools.const_get(tool).call(**arguments, server_context: nil)

  def said(response) = response.content.sole[:text]

  def save(**given)
    call(:SaveFitScore, role: role.id, resume_version: resume.version, score: 58, why: "Discovery shown; Salesforce administration isn't.",
                        matches: [ { point: "Discovery", lines: [ 3 ] } ], gaps: [ { asks: "Salesforce administration", note: "Not shown." } ],
                        background_version: background.version, background_score: 74,
                        background_why: "The background covers Salesforce; weekly demos sit less well with the preferences.",
                        covered: [ { asks: "Salesforce administration", lines: [ "B5", 99 ], address_in: "resume", note: "Add the process built." } ],
                        preferences: [ { preference: "Classic pre-sales demos fit less", verdict: "miss", why: "Weekly live demos.", lines: [ "B3" ] },
                                       { preference: "Internal-facing work", verdict: "match", lines: [ 2 ] } ],
                        model: "claude-opus-5-5", **given)
  end

  it "gives the background beside the resume, its lines numbered across its parts, with the rules for both readings" do
    text = said(call(:RolesToWeigh, roles: [ role.id ]))

    expect(text).to include(ProvenanceMcp::Writing.rules["background_fit"], "Read each role a second time with it",
                            "<background saved=\"#{background.created_at.utc.to_date}\" version=\"#{background.version}\">",
                            "What I'm looking for:\n[B1] A long-term role building revenue systems.\nRole preferences:\n[B2] Internal-facing work first.",
                            "Background not on the resume:\n[B4] Portuguese, native; English, fluent.", "In my summary, give the ATS fit first")
    expect(text.index("<resume")).to be < text.index("<background")
  end

  it "says to weigh the ATS fit alone while no background is saved" do
    Backgrounds.remove!(profile)

    text = said(call(:RolesToWeigh, roles: [ role.id ]))
    expect(text).to include("No background is saved: weigh the ATS fit alone.").and(not_include("background_fit", "Read each role a second time"))
  end

  it "saves both readings, the Background fit against the background version read, audited by its score, counts and hash" do
    text = said(save)

    score = role.fit_scores.sole
    expect(text).to start_with("Saved: 58 for Customer Engineer at Acme (1 match, 1 gap); Background fit 74 (1 gap covered, preferences " \
                               "1 met, 1 missed; 1 background line it named isn't in the background, left out).")
    expect(score).to have_attributes(score: 58, background_score: 74, background: background, background_hash: background.content_hash,
                                     background_dropped_lines: 1)
    expect(score.covered).to eq([ { "asks" => "Salesforce administration", "address_in" => "resume", "note" => "Add the process built.",
                                    "lines" => [ { "line" => 5, "text" => "Set up a first Salesforce sales-operations process.", "part" => "not_on_resume" } ] } ])
    expect(score.preferences.map { |point| [ point["verdict"], point["lines"].map { |line| line["line"] } ] }).to eq([ [ "miss", [ 3 ] ], [ "match", [ 2 ] ] ])
    event = AuditEvent.find_by!(target: score)
    expect(event.changes_made).to include("background_score" => [ nil, 74 ], "covered" => [ nil, 1 ],
                                          "preferences" => [ nil, { "match" => 1, "miss" => 1 } ], "background_hash" => [ nil, background.content_hash ])
    expect(event.changes_made.to_json).not_to include("Salesforce", "demos", "Portuguese")
  end

  it "saves the ATS fit alone when no Background fit is given, and refuses a Background fit it can't place" do
    expect(said(call(:SaveFitScore, role: role.id, resume_version: resume.version, score: 58, why: "x"))).to start_with("Saved: 58 for")
    expect(role.fit_scores.sole.background_reading?).to be(false)

    expect(said(save(background_version: "0123456789ab"))).to start_with("Not saved: background version \"0123456789ab\" isn't on record")
    expect(said(save(background_score: 140))).to eq("Not saved: a Background fit is a whole number from 0 to 100.")
    expect(said(save(background_why: " "))).to eq("Not saved: say why the Background fit is what it is, in a sentence.")
    expect(said(save(covered: [ { asks: "x", lines: [], address_in: "linkedin" } ]))).to start_with("Not saved: a covered gap is addressed in resume")
    expect(said(save(preferences: [ { preference: "x", verdict: "unknown" } ]))).to eq("Not saved: a preference is a match or a miss.")
    expect(role.fit_scores.count).to eq(1)
  end

  it "picks the roles weighed before the background as it is now, when asked, and says so in the prompt" do
    other = create(:posting, company: company, role_title: "Solutions Engineer", job_url: "https://acme.example/jobs/2")
    text = "Implementation work for internal teams."
    other.role_descriptions.create!(text: text, content_hash: Resume.digest(text), read_via: "render", url: other.job_url, run_id: "r1",
                                    first_read_at: Time.utc(2026, 11, 10, 9), last_read_at: Time.utc(2026, 11, 10, 9))
    later { save }
    later { call(:SaveFitScore, role: other.id, resume_version: resume.version, score: 66, why: "Weighed before the background.") }

    expect(FitScores.before_background([ role, other ])).to eq([ other ])
    later { Backgrounds.keep!(profile, looking_for: "Something else now.") }
    expect(FitScores.before_background([ role, other ])).to eq([ role, other ]) # the background changed since role's reading

    picked = said(call(:RolesToWeigh, before_background: true))
    expect(picked).to include("Role id #{role.id}", "Role id #{other.id}")
    prompt = ProvenanceMcp::Prompts::WeighRoles.template({ how_many: "2", before_background: "yes" }).messages.sole.to_h.dig(:content, :text)
    expect(prompt).to start_with("Weigh 2 of my roles weighed before my background as it is now, again")
    expect(prompt).to include("get_roles_to_weigh with before_background", "the Background fit with my background too")
  end
end
