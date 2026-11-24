require "rails_helper"

# The Pipeline page (4e step 4): Preparing before Applied, Screening gone; each card with its role's fit and its
# company's beside it, two scores never weighed into each other.
RSpec.describe "The Pipeline page", type: :request do
  let!(:company) { create(:company, :resolved, name: "Acme", domain: "acme.example") }
  let!(:profile) { SearchProfile.create!(titles: [ "Sales Engineer" ]) }
  let!(:resume) { Resumes.keep!(profile, text: "Jordan Sample\nSales engineer.") }
  let!(:role) { create(:posting, :verified_live, company: company, role_title: "Sales Engineer", tracking: "tracked") }

  it "has Preparing before Applied, and no Screening" do
    post applications_path, params: { posting_id: role.id, stage: "preparing", on: Date.current }
    expect(role.reload.application).to have_attributes(stage: "preparing")

    get applications_path
    expect(response.body).to include(%(<section class="column" id="preparing">)).and not_include(%(id="screening"))
    expect(response.body.index(%(id="preparing"))).to be < response.body.index(%(id="applied"))
    expect(Application::OPEN).to eq(%w[interested preparing applied interviewing offer])
  end

  it "shows each card's fit, its screen risk, and its company's fit beside it" do
    text = "Must have: Spanish."
    description = role.role_descriptions.create!(text: text, content_hash: Resume.digest(text), read_via: "render", run_id: "r1",
                                                  url: "https://acme.example/jobs/1", first_read_at: 1.day.ago, last_read_at: 1.day.ago)
    Authority.unchecked do
      role.fit_scores.create!(score: 64, why: "Discovery shown.", resume: resume, resume_hash: resume.content_hash, role_description: description,
                              description_hash: description.content_hash, written_by: "agent:assistant",
                              must_haves: [ { "asks" => "Spanish", "shown_in" => "none", "lines" => [] } ])
    end
    create(:company_review, company: company, score: 72)
    create(:application, posting: role, stage: "applied")

    get applications_path
    card = response.body[%r{<a class="card".*?</a>}m]
    expect(card).to include("Fit", ">64<", "screen risk", "Likely screened out on: Spanish", "company", ">72<")
  end
end
