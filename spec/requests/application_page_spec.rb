require "rails_helper"

# An application's page (4e step 3): where it stands, the role's fits and its company's in the header, then tabs that
# open on its activity; its writing with the newest of each kind in full and the earlier ones folded; and its history,
# holding what was saved under it, the AI assistant's resume review included.
RSpec.describe "An application's page", type: :request do
  let!(:company) { create(:company, :resolved, name: "Acme", domain: "acme.example") }
  let!(:role) { create(:posting, :verified_live, company: company, role_title: "Sales Engineer", tracking: "tracked") }
  let!(:application) { create(:application, posting: role) }
  let!(:profile) { SearchProfile.create!(titles: [ "Sales Engineer" ]) }
  let!(:resume) { Resumes.keep!(profile, text: "Jordan Sample\nSales engineer.\n- Ran discovery for 35 accounts a year.") }
  let!(:description) do
    text = "Discovery. Spanish required."
    role.role_descriptions.create!(text: text, content_hash: Resume.digest(text), read_via: "render", url: "https://acme.example/jobs/1",
                                   run_id: "r1", first_read_at: 1.day.ago, last_read_at: 1.day.ago)
  end
  let(:read_from) { { resume: resume, resume_hash: resume.content_hash, role_description: description, description_hash: description.content_hash } }

  # As the AI assistant saved them through MCP, each with its record.
  def saved_by_the_assistant
    Authority.unchecked do
      score = role.fit_scores.create!(score: 66, score_before_cap: 76, why: "Discovery shown; Spanish isn't.", written_by: "agent:assistant",
                                      must_haves: [ { "asks" => "Spanish", "shown_in" => "none", "lines" => [], "note" => "Not on the resume." } ],
                                      **read_from)
      [ 2.days.ago, 1.hour.ago ].each_with_index do |at, index|
        review = application.resume_reviews.create!(language: "English", written_by: "agent:assistant", created_at: at, note: "Review #{index + 1}.",
                                                    strengths: [ { "point" => "Discovery #{index + 1}", "lines" => [] } ], **read_from)
        AuditEvent.record!(actor: "agent:assistant", action: "create", target: review, reasoning: "Saved through MCP: review #{index + 1}.",
                           changes_made: { "language" => [ nil, "English" ] })
      end
      AuditEvent.record!(actor: "agent:assistant", action: "create", target: score, reasoning: "Saved through MCP: 66.",
                         changes_made: { "score" => [ nil, 66 ] })
    end
    [ 3.days.ago, 2.hours.ago ].each do |at|
      application.drafts.create!(kind: "cover_letter", language: "English", body: "Dear Acme, written #{at.to_date}.", written_body: "x",
                                 written_by: "agent:assistant", run_id: "r1", created_at: at, **read_from)
    end
    create(:company_review, company: company, score: 72, why: "Builds for revenue teams.")
  end

  it "opens on its activity, its role's fits, its company's fit and its screen risk in the header" do
    saved_by_the_assistant
    get application_path(application)

    body = response.body
    expect(body).to include("ATS fit", "Company fit", "Likely screened out on: Spanish.", "Move it", "Log what happened")
    expect(body).to include(%(id="activity-tab" role="tab" aria-controls="activity" aria-selected="true"))
    expect(body).to match(/<section id="fit" class="tab-panel"[^>]*hidden="hidden"/)
    expect(body).to include("Builds for revenue teams.", "never weighed into the role's fit", "Its full review")
    expect(body).to include(%(<input type="hidden" name="from" id="from" value="application"))
  end

  it "shows the newest review and the newest draft of each kind, the earlier ones folded" do
    saved_by_the_assistant
    get application_path(application)

    body = response.body
    expect(body).to include("1 earlier review", "1 earlier cover letter")
    expect(body.index("Review 2.")).to be < body.index("1 earlier review")
    expect(body.index("1 earlier review")).to be < body.index("Review 1.")
    expect(body.index("written #{2.hours.ago.to_date}")).to be < body.index("1 earlier cover letter")
  end

  it "keeps in its history what was saved under it, a deleted activity included" do
    saved_by_the_assistant
    Pipeline.log!(application, kind: "email", on: Date.current, summary: "Wrote to the recruiter.")
    activity = application.activities.sole
    Pipeline.delete_activity!(activity)
    get application_path(application)

    expect(response.body).to include("resume review written", "Saved through MCP: review 2.", "logged: email", "activity deleted")
    expect(response.body).not_to include("fit weighed") # the role's fit is on the role's page
  end

  it "comes back to the application after weighing its fit from it" do
    post fit_scores_path, params: { posting_id: role.id, from: "application" }
    expect(response).to redirect_to(application_path(application, anchor: "fit"))
  end
end
