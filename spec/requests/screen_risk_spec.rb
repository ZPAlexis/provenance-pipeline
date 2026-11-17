require "rails_helper"

# Screen risk on the pages (4d step 1): a role's page reads its must-haves one by one above both fits, saying what a
# screener wouldn't find on the resume and what that capped; the Roles table marks the risk, and picks the roles
# weighed before the check.
RSpec.describe "Screen risk, on the pages", type: :request do
  let!(:company) { create(:company, :resolved, name: "Acme", domain: "acme.example") }
  let!(:profile) { SearchProfile.create!(titles: [ "Solutions Engineer" ]) }
  let!(:resume) { Resumes.keep!(profile, text: "Jordan Sample\nSolutions engineer.\n- Ran discovery for 35 accounts a year.") }
  let!(:screened) { create(:posting, company: company, role_title: "Senior AI Solutions Engineer", tracking: "tracked") }
  let!(:unscreened) { create(:posting, company: company, role_title: "Deal Desk Analyst", tracking: "tracked") }

  def weigh(posting, score, **reading)
    text = "Minimum requirements: 3+ years of hands-on AI."
    description = posting.role_descriptions.create!(text: text, content_hash: Resume.digest(text), read_via: "render",
                                                    url: "https://acme.example/jobs/#{posting.id}", run_id: "r1",
                                                    first_read_at: 1.day.ago, last_read_at: 1.day.ago)
    posting.fit_scores.create!(score: score, why: "Discovery shown.", resume: resume, resume_hash: resume.content_hash, role_description: description,
                               description_hash: description.content_hash, written_by: "agent:assistant", **reading)
  end

  before do
    weigh(screened, 69, score_before_cap: 74, must_haves: [
      { "asks" => "3+ years of hands-on AI", "shown_in" => "none", "lines" => [], "note" => "The AI work starts in 2026." },
      { "asks" => "Discovery", "shown_in" => "resume", "lines" => [ { "line" => 3, "text" => "- Ran discovery for 35 accounts a year." } ] }
    ])
    weigh(unscreened, 66)
  end

  it "reads the must-haves above both fits on a role's page, and what capped the ATS fit" do
    get role_path(screened)

    expect(response.body).to include("Screen risk", "Likely screened out on: 3+ years of hands-on AI.", "not shown", "on the resume",
                                     "The AI work starts in 2026.", "[3] - Ran discovery for 35 accounts a year.", "of 100, capped from 74",
                                     "One not on your resume caps the ATS fit at 69")
    expect(response.body.index("Screen risk")).to be < response.body.index("ATS fit")

    get role_path(unscreened)
    expect(response.body).to include("Weighed before the screen check: weigh it again to read its must-haves one by one.")
  end

  it "marks the risk in the Roles table, and picks the roles weighed before the check" do
    get roles_path

    expect(response.body).to include("screen risk", "Not on the resume: 3+ years of hands-on AI. Capped from 74",
                                     "Before the screen check <span class=\"count\">1</span>")
    get roles_path(fit: "before_screen")
    expect(response.body).to include("Deal Desk Analyst").and(not_include("Senior AI Solutions Engineer"))
  end

  # 4d step 2: the in-app fit scorer reads must-haves too, so the Roles page offers to weigh those roles again.
  it "offers to weigh again, in the app, the roles weighed before the screen check, what it costs asked first" do
    get roles_path
    expect(response.body).to include("Weigh again 1 role weighed before the screen check", "its must-haves read one by one")

    expect { post fit_scores_path, params: { before_screen: 1 } }.to have_enqueued_job(CheckNowJob)
    expect(CheckRun.sole).to have_attributes(kind: "fit", request: include("posting_ids" => [ unscreened.id ]))
  end
end
