require "rails_helper"
require Rails.root.join("mcp/provenance_mcp")
ProvenanceMcp.tools
ProvenanceMcp.prompts

# The operator's links read as background (4d step 4): for each role, the lines of their links' pages that apply to it,
# numbered on after the background's, read by the Background fit, resume reviews and tailored resumes (never the ATS fit,
# a preference, or a letter), in the app and through MCP, a client's citations read back against the links' version. A
# read tool's call leaves the test's transaction read-only: each example writes before its first such call.
RSpec.describe "The operator's links, read as background", type: :request do
  let!(:company) { create(:company, :resolved, name: "Acme", domain: "acme.example") }
  let!(:profile) { SearchProfile.create!(titles: [ "Solutions Engineer" ], places: [ "Brazil" ], work_modes: [ "remote" ]) }
  let!(:resume) { Resumes.keep!(profile, text: "Jordan Sample\nSolutions engineer, 2021 to now.\n- Ran discovery for 35 accounts a year.") }
  let!(:background) { later { Backgrounds.keep!(profile, not_on_resume: "Spanish, conversational.") } }
  let!(:role) { create(:posting, company: company, role_title: "Solutions Engineer", job_url: "https://acme.example/jobs/1", tracking: "tracked") }
  let!(:description) do
    text = "You will build governed agents with an audit log, in Rails and Playwright. Rails a must."
    role.role_descriptions.create!(text: text, content_hash: Resume.digest(text), read_via: "render", url: role.job_url, run_id: "r1",
                                   first_read_at: 1.day.ago, last_read_at: 1.day.ago)
  end
  let(:application) { create(:application, posting: role) }

  before do
    link = ProfileLinks.keep!(profile, [ { label: "Website", url: "https://jordan.example/en" } ]).sole
    at = Time.utc(2026, 11, 17, 12)
    { "Project Alpha" => "Project Alpha\nAn agent with an append-only audit log.\nBuilt with Rails and Playwright.\nMy cat is called Pixel.",
      "Recipes" => "Recipes\nBread, baked weekly." }.each do |title, text|
      link.link_pages.create!(url: "https://jordan.example/en/#{title.parameterize}", title: title, text: text, content_hash: Resume.digest(text),
                              read_via: "render", run_id: "r1", first_read_at: at, last_read_at: at)
    end
    link.update!(read_at: at, read_outcome: "ok")
  end

  def call(tool, **arguments) = ProvenanceMcp::Tools.const_get(tool).call(**arguments, server_context: nil)

  def said(response) = response.content.sole[:text]

  def reading = ProfileLinks.reading(background, profile, description)

  it "picks what applies to the role, numbered on after the background's lines, citable by what may read it" do
    expect(ProfileLinks.applicable(profile, description.text)).to eq([
      { "url" => "https://jordan.example/en/project-alpha", "title" => "Project Alpha",
        "lines" => [ "An agent with an append-only audit log.", "Built with Rails and Playwright." ] }
    ]) # the recipes, and the cat, share nothing with the role
    expect(ProfileLinks.applicable(profile, "A data engineer: Spark and Airflow, with an audit log.")).to eq([]) # one word alone
    expect(ProfileLinks.words("Agents, the analytics process, and this.")).to eq(%w[agent analytic process].to_set)

    expect(reading.numbered_lines).to eq([ [ 1, "Spanish, conversational.", "not_on_resume" ],
                                          [ 2, "An agent with an append-only audit log.", "links", "Project Alpha" ],
                                          [ 3, "Built with Rails and Playwright.", "links", "Project Alpha" ] ])
    expect([ reading.citable("not_on_resume"), reading.citable("looking_for"), background.citable("not_on_resume") ])
      .to eq([ %w[not_on_resume links], %w[looking_for], %w[not_on_resume] ])
    expect([ reading.links_version, background.links_version ]).to match([ /\A\h{12}\z/, nil ])

    target = FitScores.target(role, resume: resume, description: description, profile: profile, background: reading)
    expect(target[:background].last).to eq(line: 3, text: "Built with Rails and Playwright.", part: "links", source: "Project Alpha")
    review = ResumeReviews.target(application, language: nil, resume: resume, description: description, profile: profile, background: reading)
    expect(review[:not_on_resume].map { |line| line[:part] }).to eq(%w[not_on_resume links links])
  end

  it "gives each role its links' lines through MCP, with their version, and a resume review its role's" do
    application # written before the first read tool's call
    version = reading.links_version

    weighing = said(call(:RolesToWeigh, roles: [ role.id ]))
    expect(weighing).to include("<links version=\"#{version}\">\nProject Alpha:\n[B2] An agent with an append-only audit log.",
                                "give that role's links_version")
    materials = said(call(:ApplicationMaterials, application: application.id, kind: "resume_review"))
    expect(materials).to include("<links version=\"#{version}\">
Project Alpha:
[B2]")
    expect(said(call(:WritingRules, kind: "resume_review"))).to include("Lines from my own links, numbered on after my background's")
    expect(said(call(:ApplicationMaterials, application: application.id, kind: "cover_letter"))).not_to include("<links")
  end

  it "reads a covered gap or a must-have on a line of the links back with their version, and refuses another version" do
    version = reading.links_version
    weigh = lambda do |**given|
      said(call(:SaveFitScore, role: role.id, resume_version: resume.version, score: 60, why: "Discovery shown.", must_haves: [],
                               background_version: background.version, background_score: 72, background_why: "The links show Rails.",
                               covered: [ { asks: "Audit logs", lines: [ "B2" ], address_in: "resume" } ], **given))
    end

    later { weigh.call(links_version: version, must_haves: [ { asks: "Rails", shown_in: "background", background_lines: [ "B3" ] } ]) }
    score = role.fit_scores.sole
    expect(score.covered.sole["lines"]).to eq([ { "line" => 2, "text" => "An agent with an append-only audit log.", "part" => "links",
                                                  "source" => "Project Alpha" } ])
    expect(score.must_haves.sole["background_lines"].sole).to include("part" => "links", "line" => 3)

    expect(weigh.call(links_version: "0123456789ab")).to start_with("Not saved: links version \"0123456789ab\" isn't the one on record")
    later { weigh.call } # no version: the links' lines aren't read, so B2 names no line
    expect(role.fit_scores.newest_first.first).to have_attributes(background_dropped_lines: 1)
  end

  it "flags a resume review's point drawn from the links, on the application's page" do
    version = reading.links_version
    saved = said(call(:SaveResumeReview, application: application.id, resume_version: resume.version, language: "English",
                                         strengths: [ { point: "Audit logs", lines: [], background_lines: [ "B2" ] },
                                                      { point: "Spanish", lines: [], background_lines: [ "B1" ] } ],
                                         background_version: background.version, links_version: version))
    expect(saved).to include("2 drawn from your background and your links, not on the resume, for you to confirm")

    expect(application.resume_reviews.sole.strengths.first["background_lines"].sole).to include("part" => "links", "source" => "Project Alpha")
    expect(WrittenFrom.flagged([ { "background_lines" => [ { "part" => "links" } ] } ])).to start_with("1 drawn from your links,")
    get application_path(application)
    expect(response.body).to include("from your links, not on the resume: confirm it",
                                     "[B2] An agent with an append-only audit log. (your links: Project Alpha)")
  end

  # In the app: the fit scorer is given the role's own lines of the links, and what it draws on them is kept with its page.
  it "gives the in-app fit scorer each role's lines of the links, and keeps a covered gap drawn on one" do
    run_dir = Rails.root.join("tmp/verifier/20261118T120000Z-fit-links-spec")
    line = { "line" => 2, "text" => "An agent with an append-only audit log.", "part" => "links", "source" => "Project Alpha" }
    result = { "kind" => "fit", "target_id" => role.id, "outcome" => "ok", "score" => 64, "level" => "Mid", "matches" => [], "gaps" => [],
               "why" => "Discovery shown.", "dropped_lines" => 0, "background_score" => 75, "background_why" => "The links show an audit log.",
               "covered" => [ { "asks" => "Audit logs", "lines" => [ line ], "address_in" => "resume", "note" => "Add it." } ],
               "preferences" => [], "background_dropped_lines" => 0, "must_haves" => [],
               "llm" => { "model" => "claude-haiku-4-5", "settings" => {}, "purpose" => "fit", "prompt_version" => "f", "input_tokens" => 1,
                          "output_tokens" => 1, "cost_usd" => 0.001 } }
    worker = Class.new do
      attr_reader :asked, :run_dir

      def initialize(result, run_dir) = (@result, @run_dir = result, run_dir)

      def run(targets, command:)
        @asked = targets
        Verifier::Worker::Run.new(dir: @run_dir, results: [ @result ], stopped: nil)
      end
    end.new(result, run_dir)

    FitScores.weigh!(role, worker: worker)

    expect(worker.asked.sole[:background].map { |given| given[:part] }).to eq(%w[not_on_resume links links])
    expect(role.fit_scores.sole.covered.sole["lines"]).to eq([ line ])
  ensure
    FileUtils.rm_rf(run_dir)
  end
end
