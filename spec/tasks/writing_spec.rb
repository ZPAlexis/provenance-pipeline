require "rails_helper"

# The commands over what is written for an application and how roles fit (2c, 2d, 2f), as the operator runs them. The
# ones that call the model are refused here before any run; the services' own specs cover a run.
RSpec.describe "drafts:, reviews: and fit: commands" do
  let!(:company) { create(:company, :resolved, name: "Acme", domain: "acme.example") }
  let!(:role) { create(:posting, company: company, role_title: "Sales Engineer", tracking: "tracked", job_url: "https://acme.example/jobs/1") }
  let!(:application) { create(:application, posting: role) }
  let!(:profile) { SearchProfile.create!(titles: [ "Sales Engineer" ]) }

  def resume = profile.resumes.newest_first.first || Resumes.keep!(profile, text: "Alex Example\nRan technical discovery for 40 accounts.")

  def description
    role.role_descriptions.first || role.role_descriptions.create!(
      text: "Discovery. Spanish required.", content_hash: Resume.digest("Discovery. Spanish required."), read_via: "render",
      url: role.job_url, run_id: "r1", first_read_at: 1.day.ago, last_read_at: 1.day.ago
    )
  end

  def call(purpose) = LlmCall.create!(run_id: "r1", purpose: purpose, model: "claude-opus-5-5", settings: {}, prompt_version: "p1",
                                      input_tokens: 2_000, output_tokens: 1_000, cost_usd: 0.063, called_at: Time.current)

  it "lists and shows a draft, and approves it as the operator; nothing is sent" do
    draft = application.drafts.create!(kind: "cover_letter", language: "English", body: "Dear Acme team,", written_body: "Dear Acme team,",
                                       resume: resume, resume_hash: resume.content_hash, role_description: description,
                                       description_hash: description.content_hash, llm_call: call("draft"), run_id: "r1",
                                       drew_on: [ { "line" => 2, "text" => "Ran technical discovery for 40 accounts.", "used_for" => "discovery" } ],
                                       gaps: [ { "asks" => "Spanish", "note" => "Not shown." } ])

    expect(run_task("drafts:list").out).to include(draft.id, "Acme / Sales Engineer: cover letter in English", "a draft", "$0.063")
    expect(run_task("drafts:show", draft.id).out).to include("Dear Acme team,", "- Spanish: Not shown.", "[2] Ran technical discovery")
    expect(run_task("drafts:approve", draft.id).out).to include("approved. Nothing is sent")
    expect(draft.reload).to be_approved
    expect(AuditEvent.find_by!(target: draft, action: "update").actor).to eq(AuditEvent::OPERATOR)
    expect(run_task("drafts:approve", draft.id).aborted).to start_with("It is approved already")
  end

  it "refuses to write or review before any backup when what it needs is missing, and says when nothing is written yet" do
    expect(run_task("drafts:write", application.id, KIND: "thank_you").aborted).to start_with("KIND is one of:")
    expect(run_task("drafts:write", application.id, KIND: "cover_letter").aborted).to start_with("Drafting needs a resume")
    expect(run_task("reviews:write", application.id).aborted).to include("needs a resume")
    expect(run_task("drafts:list").aborted).to start_with("No draft yet")
    expect(run_task("reviews:list").aborted).to start_with("No review yet")
    expect(DatabaseBackup).not_to have_received(:call)
  end

  it "shows roles by fit and one score in full, and plans a weighing with its cost without running it" do
    role.fit_scores.create!(score: 72, level: "Mid-level", why: "Strong on discovery; Spanish is missing.",
                            matches: [ { "point" => "Discovery at volume", "lines" => [ { "line" => 2, "text" => "Ran technical discovery." } ] } ],
                            gaps: [ { "asks" => "Spanish", "note" => "Not shown." } ], resume: resume, resume_hash: resume.content_hash,
                            role_description: description, description_hash: description.content_hash, written_by: "agent:fit_scorer")
    create(:posting, company: company, role_title: "Solutions Engineer", tracking: "suggested", job_url: "https://acme.example/jobs/2")

    expect(run_task("fit:list").out).to include(" 72  #{role.id}  Acme / Sales Engineer (tracked, applied)")
    expect(run_task("fit:show", role.id).out).to include("Acme / Sales Engineer: 72 of 100", "Discovery at volume [line 2]", "- Spanish: Not shown.")
    planned = run_task("fit:score")
    expect(planned.out).to include("1 role unscored: 1 can be weighed", "Run it with GO=1.")
    expect(FitScore.count).to eq(1)
    expect(DatabaseBackup).not_to have_received(:call)
  end
end
