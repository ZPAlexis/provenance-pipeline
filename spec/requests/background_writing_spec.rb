require "rails_helper"

# What a resume review or a tailored resume drew from the background, on the application's page (4c step 3): each point,
# suggestion or change flagged "from your background, not on the resume" for the operator to confirm, with the lines it
# rests on; and when the part it read changed since.
RSpec.describe "Writing drawn from the background, on the application's page", type: :request do
  let!(:company) { create(:company, :resolved, name: "Acme", domain: "acme.example") }
  let!(:role) { create(:posting, :verified_live, company: company, role_title: "Sales Engineer") }
  let!(:application) { create(:application, posting: role) }
  let!(:profile) { SearchProfile.create!(titles: [ "Sales Engineer" ]) }
  let!(:resume) { Resumes.keep!(profile, text: "Jordan Sample\nSales engineer, eight years.") }
  let!(:background) { later { Backgrounds.keep!(profile, not_on_resume: "Set up a first Salesforce sales-operations process.") } }
  let(:drawn) { [ { "line" => 1, "text" => "Set up a first Salesforce sales-operations process.", "part" => "not_on_resume" } ] }

  before do
    read = { resume: resume, resume_hash: resume.content_hash, description_hash: "sha256:d", written_by: "agent:assistant",
             background: background, background_hash: background.hash_of("not_on_resume") }
    application.resume_reviews.create!(language: "English", strengths: [ { "point" => "A Salesforce process", "lines" => [], "background_lines" => drawn } ],
                                       suggestions: [ { "change" => "Add the process you set up", "lines" => [], "background_lines" => drawn } ], **read)
    application.drafts.create!(kind: "tailored_resume", language: "English", body: "Jordan Sample.", written_body: "Jordan Sample.", run_id: "mcp:x",
                               tailoring: [ { "change" => "Added the Salesforce process", "lines" => [], "background_lines" => drawn } ], **read)
  end

  it "flags what a review or a tailored resume drew from the background, with its lines, for the operator to confirm" do
    get application_path(application)

    body = response.body
    expect(body.scan("from your background, not on the resume: confirm it").size).to eq(3)
    expect(body).to include("[B1] Set up a first Salesforce sales-operations process.", "A Salesforce process", "Added the Salesforce process")
    expect(body).not_to include("Your background not on the resume has changed", "the background it read")
  end

  it "says when the part they read has changed since" do
    later { Backgrounds.keep!(profile, not_on_resume: "Something else now.") }

    get application_path(application)
    expect(response.body).to include("Your background not on the resume has changed since it was written.",
                                     "The background it read has changed since it was written")
  end
end
