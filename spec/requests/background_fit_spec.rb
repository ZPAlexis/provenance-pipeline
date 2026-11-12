require "rails_helper"

# A role's fit read two ways on the pages (4c step 2): the tables show the ATS fit, the resume alone as a recruiter's
# screening system would read it; a role's page shows both readings, the gaps the background covers and the role
# preferences, says when one was weighed before the background, and the Roles page picks those to weigh again.
RSpec.describe "A role's fit read two ways, on the pages", type: :request do
  let!(:company) { create(:company, :resolved, name: "Acme", domain: "acme.example") }
  let!(:profile) { SearchProfile.create!(titles: [ "Sales Engineer" ]) }
  let!(:resume) { Resumes.keep!(profile, text: "Jordan Sample\nSales engineer, eight years.") }
  let!(:background) do
    later { Backgrounds.keep!(profile, role_preferences: "Internal-facing work first.", not_on_resume: "Set up a first Salesforce process.") }
  end
  let!(:weighed) { create(:posting, company: company, role_title: "Customer Engineer", tracking: "tracked") }
  let!(:before) { create(:posting, company: company, role_title: "Deal Desk Analyst", tracking: "tracked") }

  def describe_and_score(posting, score, **reading)
    text = "Run discovery. Salesforce a must."
    description = posting.role_descriptions.create!(text: text, content_hash: Resume.digest(text), read_via: "render", url: "https://acme.example/jobs/1",
                                                    run_id: "r1", first_read_at: 1.day.ago, last_read_at: 1.day.ago)
    later do
      posting.fit_scores.create!(score: score, why: "Discovery shown.", resume: resume, resume_hash: resume.content_hash, role_description: description,
                                 description_hash: description.content_hash, written_by: "agent:assistant", **reading)
    end
  end

  before do
    describe_and_score(weighed, 58, background_score: 74, background_why: "The background covers Salesforce.", background: background,
                                    background_hash: background.content_hash,
                                    covered: [ { "asks" => "Salesforce", "address_in" => "resume", "note" => "Add the process.",
                                                 "lines" => [ { "line" => 2, "text" => "Set up a first Salesforce process.", "part" => "not_on_resume" } ] } ],
                                    preferences: [ { "preference" => "Internal-facing work", "verdict" => "match", "why" => "Internal tools.",
                                                     "lines" => [ { "line" => 1, "text" => "Internal-facing work first.", "part" => "role_preferences" } ] } ])
    describe_and_score(before, 66)
  end

  it "shows the ATS fit in the tables, and picks the roles weighed before the background" do
    get roles_path

    expect(response.body).to include("ATS fit</a>", "ATS fit:", "Before your background <span class=\"count\">1</span>", ">58<", ">66<")
    get roles_path(fit: "before_background")
    expect(response.body).to include("Deal Desk Analyst").and(not_include("Customer Engineer"))
  end

  # 4c step 5: the in-app fit scorer reads the background too, so the Roles page offers to weigh those roles again.
  it "offers to weigh again, in the app, the roles weighed before the background, what it costs asked first" do
    get roles_path
    expect(response.body).to include("Weigh again 1 role weighed before your background", "the ATS fit and the Background fit")

    expect { post fit_scores_path, params: { before_background: 1 } }.to have_enqueued_job(CheckNowJob)
    expect(CheckRun.sole).to have_attributes(kind: "fit", request: include("posting_ids" => [ before.id ]))
  end

  it "shows both readings on a role's page, the covered gaps and the preferences, and when the background changed since" do
    get role_path(weighed)

    expect(response.body).to include("ATS fit", "Your resume alone, as a recruiter", "Background fit", ">74<", "The background covers Salesforce.",
                                     "Gaps your background covers", "address it in the resume. Add the process.",
                                     "[B2] Set up a first Salesforce process.", "Your role preferences", ">met<", "Internal-facing work: Internal tools.")
    expect(response.body).not_to include("Your background changed since")

    later { Backgrounds.keep!(profile, role_preferences: "Remote first.") }
    get role_path(weighed)
    expect(response.body).to include("Your background changed since: weigh it again for a current Background fit.")
  end

  it "says when a role was weighed before the background, or asks for one" do
    get role_path(before)
    expect(response.body).to include("Before your background: weighed from your resume alone.")

    Backgrounds.remove!(profile)
    get role_path(before)
    expect(response.body).to include("Save your <a href=\"/profile#background\">background</a> on the Profile page")
  end
end
