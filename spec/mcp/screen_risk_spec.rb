require "rails_helper"
require Rails.root.join("mcp/provenance_mcp")
ProvenanceMcp.tools
ProvenanceMcp.prompts

# Screen risk through MCP (4d step 1): each must-have a role states, read one by one, shown on the resume, shown only in
# the background, or not shown. One not on the resume caps the ATS fit at 69, one shown nowhere the Background fit, and
# the app applies the cap, keeping the score as weighed beside it. A read tool's or a prompt's call leaves the test's
# transaction read-only: each example writes before its first such call.
RSpec.describe "Screen risk, through MCP" do
  let!(:company) { create(:company, :resolved, name: "Acme", domain: "acme.example") }
  let!(:profile) { SearchProfile.create!(titles: [ "Solutions Engineer" ], places: [ "Brazil", "LATAM" ], work_modes: [ "remote" ]) }
  let!(:resume) do
    Resumes.keep!(profile, text: "Jordan Sample\nSolutions engineer, Fabrikam, 2021 to now.\n- Ran discovery for 35 accounts a year.\n" \
                                 "- Built an AI agent for this job search, 2026.")
  end
  let!(:background) { later { Backgrounds.keep!(profile, not_on_resume: "Ran an AI pilot for the sales team in 2024.") } }
  let!(:role) { create(:posting, company: company, role_title: "Senior AI Solutions Engineer", job_url: "https://acme.example/jobs/1") }

  before do
    text = "Minimum requirements: 3+ years of hands-on AI; production AI agents; discovery with buyers. Bonus: Clay."
    role.role_descriptions.create!(text: text, content_hash: Resume.digest(text), read_via: "render", url: role.job_url, run_id: "r1",
                                   first_read_at: Time.utc(2026, 11, 10, 9), last_read_at: Time.utc(2026, 11, 10, 9))
  end

  def call(tool, **arguments) = ProvenanceMcp::Tools.const_get(tool).call(**arguments, server_context: nil)

  def said(response) = response.content.sole[:text]

  let(:musts) do
    [ { asks: "3+ years of hands-on AI", shown_in: "none", note: "The resume's AI work starts in 2026." },
      { asks: "Production AI agents", shown_in: "background", background_lines: [ "B1" ] },
      { asks: "Discovery with buyers", shown_in: "resume", lines: [ 3 ] } ]
  end

  def save(posting = role, **given)
    call(:SaveFitScore, role: posting.id, resume_version: resume.version, score: 74, why: "Discovery shown; the AI years aren't.",
                        background_version: background.version, background_score: 80, background_why: "The pilot shows agents at work.",
                        must_haves: musts, model: "claude-opus-5-5", **given)
  end

  it "gives the must-haves rules and where the operator can work" do
    text = said(call(:RolesToWeigh, roles: [ role.id ]))

    expect(text).to include(ProvenanceMcp::Writing.rules["must_haves"], "Read its must-haves first",
                            "Where they can work: Brazil, LATAM; how: remote", "any must-have I'd likely be screened out on")
  end

  it "caps the ATS fit at 69 for a must-have not on the resume, the Background fit for one shown nowhere, keeping each as weighed" do
    text = said(save)

    score = role.fit_scores.sole
    expect(text).to start_with("Saved: 69 for Senior AI Solutions Engineer at Acme (0 matches, 0 gaps); Background fit 69 (0 gaps covered, " \
                               "preferences 0 met, 0 missed); screen risk: 2 of 3 must-haves not on the resume, the ATS fit capped from 74, " \
                               "the Background fit capped from 80.")
    expect(score).to have_attributes(score: 69, score_before_cap: 74, background_score: 69, background_score_before_cap: 80, capped?: true)
    expect(score.must_haves).to eq([
      { "asks" => "3+ years of hands-on AI", "shown_in" => "none", "lines" => [], "note" => "The resume's AI work starts in 2026." },
      { "asks" => "Production AI agents", "shown_in" => "background", "lines" => [],
        "background_lines" => [ { "line" => 1, "text" => "Ran an AI pilot for the sales team in 2024.", "part" => "not_on_resume" } ] },
      { "asks" => "Discovery with buyers", "shown_in" => "resume", "lines" => [ { "line" => 3, "text" => "- Ran discovery for 35 accounts a year." } ] }
    ])
    expect(score.screen_risks.map { |must| must["asks"] }).to eq([ "3+ years of hands-on AI", "Production AI agents" ])
    event = AuditEvent.find_by!(target: score)
    expect(event.changes_made).to include("score" => [ nil, 69 ], "score_before_cap" => [ nil, 74 ], "background_score_before_cap" => [ nil, 80 ],
                                          "must_haves" => [ nil, { "resume" => 1, "background" => 1, "none" => 1 } ])
    expect(event.changes_made.to_json).not_to include("hands-on", "pilot", "discovery")
  end

  it "keeps a score already under the cap as weighed, caps nothing when every must-have is on the resume, and reads none stated" do
    later { expect(said(save(score: 60, background_score: 66))).to include("screen risk: 2 of 3 must-haves not on the resume.") }
    expect(role.fit_scores.sole).to have_attributes(score: 60, score_before_cap: nil, background_score: 66, background_score_before_cap: nil)

    other = create(:posting, company: company, role_title: "Solutions Engineer", job_url: "https://acme.example/jobs/2")
    other.role_descriptions.create!(text: "Discovery.", content_hash: Resume.digest("Discovery."), read_via: "render", url: other.job_url,
                                    run_id: "r1", first_read_at: 1.day.ago, last_read_at: 1.day.ago)
    later { expect(said(save(other, score: 81, must_haves: [ musts.last ]))).to include("; every must-have (1) on the resume.") }
    expect(other.fit_scores.sole).to have_attributes(score: 81, capped?: false, background_score: 80)
    later { expect(said(save(other, must_haves: []))).to include("; the role states no must-have.") }
    expect(other.fit_scores.newest_first.first).to have_attributes(score: 74, must_haves: [])
  end

  it "refuses must-haves it can't place, and a save that leaves them out" do
    expect(said(save(must_haves: nil))).to start_with("Give must_haves: each must-have the role states")
    expect(said(save(must_haves: [ { asks: "x", shown_in: "maybe" } ])))
      .to eq("Not saved: a must-have is shown on the resume, only in the background, or not at all: shown_in is resume, background or none.")
    expect(said(save(must_haves: [ { asks: "Discovery", shown_in: "resume", lines: [ 99 ] } ])))
      .to eq("Not saved: \"Discovery\" is shown on the resume: name the resume lines that show it.")
    expect(said(save(must_haves: [ { asks: "Agents", shown_in: "background", background_lines: [] } ])))
      .to eq("Not saved: \"Agents\" is shown in the background: name its background lines.")
    expect(said(save(background_version: nil, background_score: nil, background_why: nil, must_haves: [ musts[1] ])))
      .to eq("Not saved: \"Production AI agents\" is shown only in the background, but no Background fit was given.")
    expect(role.fit_scores).to be_empty
  end

  it "picks the roles weighed before the screen check, when asked, and says so in the prompt" do
    other = create(:posting, company: company, role_title: "Solutions Engineer", job_url: "https://acme.example/jobs/2")
    other.role_descriptions.create!(text: "Discovery.", content_hash: Resume.digest("Discovery."), read_via: "render", url: other.job_url,
                                    run_id: "r1", first_read_at: 1.day.ago, last_read_at: 1.day.ago)
    save
    other.fit_scores.create!(score: 66, why: "Weighed before the check.", resume: resume, resume_hash: resume.content_hash,
                             role_description: other.role_descriptions.sole, description_hash: other.role_descriptions.sole.content_hash,
                             written_by: "agent:assistant")
    role.update_columns(tracking: "tracked")
    other.update_columns(tracking: "tracked")

    expect(FitScores.before_screen([ role, other ])).to eq([ other ])
    picked = said(call(:RolesToWeigh, before_screen: true))
    expect(picked).to include("Role id #{other.id}").and(not_include("Role id #{role.id}"))
    expect(said(call(:RolesToWeigh, before_screen: true, before_background: true))).to include("one at a time")
    prompt = ProvenanceMcp::Prompts::WeighRoles.template({ how_many: "3", before_screen: "yes" }).messages.sole.to_h.dig(:content, :text)
    expect(prompt).to start_with("Weigh 3 of my roles weighed before the screen check, again")
    expect(prompt).to include("get_roles_to_weigh with before_screen", "reading its must-haves")
  end

  it "keeps the tool's values in step with the app's" do
    expect(ProvenanceMcp::Tools::SaveFitScore::SHOWN_IN).to eq(FitScore::SHOWN_IN.keys)
  end
end
