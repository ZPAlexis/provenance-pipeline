require "rails_helper"

RSpec.describe "What the client saved, on the application's page", type: :request do
  let!(:company) { create(:company, :resolved, name: "Acme", domain: "acme.example") }
  let!(:role) { create(:posting, :verified_live, company: company, role_title: "Sales Engineer") }
  let!(:application) { create(:application, posting: role) }
  let!(:profile) { SearchProfile.create!(titles: [ "Sales Engineer" ]) }
  let!(:resume) { Resumes.keep!(profile, text: "Jordan Sample\nSales engineer, eight years.\n- Ran discovery for 35 accounts a year.") }

  before do
    role.role_descriptions.create!(text: "Discovery. Spanish required.", content_hash: Resume.digest("Discovery. Spanish required."),
                                   read_via: "render", url: "https://acme.example/jobs/1", run_id: "r1", first_read_at: 1.day.ago,
                                   last_read_at: 1.day.ago)
  end

  # As the save tools save them: as agent:assistant, under a credential for the call.
  def assistant(&block) = as_agent("agent:assistant", &block)

  it "offers a resume review in the app or from your own client, and only the drafter's kinds of draft" do
    get application_path(application)

    expect(response.body).to include("Resume reviews", "Or ask your own Claude client for one through MCP (the Resume review prompt)")
    expect(response.body).to include("<option value=\"cover_letter\">Cover letter</option>", "<option value=\"outreach\">Outreach note</option>")
    expect(response.body).not_to include("<option value=\"tailored_resume\">")
  end

  describe "the in-app review" do
    include ActiveJob::TestHelper

    it "is offered with what it costs, and queued in the background in the language asked, one at a time" do
      get application_path(application)
      expect(response.body).to include("Review my resume", "about $0.070", "Opus 5.5 weighs your resume")

      expect { post application_resume_reviews_path(application), params: { language: " Portuguese " } }.to have_enqueued_job(CheckNowJob)
      expect(CheckRun.sole).to have_attributes(kind: "review", posting: role, ceiling_usd: 0.07, request: { "language" => "Portuguese" })
      post application_resume_reviews_path(application)
      expect(CheckRun.count).to eq(1)

      get application_path(application)
      expect(response.body).to include("Waiting for the check before it to finish").and(not_include("Review my resume"))
      get root_path
      expect(response.body).to include("(a resume review)", "/applications/#{application.id}#reviews")
    end

    it "is refused before anything is queued without a resume" do
      Resume.delete_all

      post application_resume_reviews_path(application)

      expect(flash[:alert]).to start_with("Not reviewed: reviewing needs a resume, saved on the Profile page")
      expect(CheckRun.count).to eq(0)
    end

    it "shows the drafter's review with its model and cost" do
      call = LlmCall.create!(run_id: "r", purpose: "review", model: "claude-opus-5-5", settings: { "output_config" => { "effort" => "medium" } },
                             prompt_version: "12a32d559f0c", input_tokens: 4_000, output_tokens: 2_000, cost_usd: 0.056, called_at: Time.current)
      application.resume_reviews.create!(language: "English", gaps: [ { "asks" => "Spanish", "note" => "Not shown." } ], resume: resume,
                                         resume_hash: resume.content_hash, description_hash: "h", written_by: "agent:drafter", llm_call: call)

      get application_path(application)

      expect(response.body).to include("Written by the in-app drafter with claude-opus-5-5 at medium effort for $0.056")
    end
  end

  it "shows a review with its strengths and lines, its gaps, suggestions and note, and who wrote it" do
    assistant do
      ResumeReviews.save!(application, language: "English", resume_version: resume.version, note: "A close fit.", reported_model: "claude-opus-5-5",
                                       strengths: [ { point: "Discovery at volume", lines: [ 3 ] } ], gaps: [ { asks: "Spanish", note: "Not shown." } ],
                                       suggestions: [ { change: "Lead with discovery", lines: [ 3, 1 ] } ])
    end

    get application_path(application)

    expect(response.body).to include("1 review", "Discovery at volume", "· line 3", "Spanish", "Lead with discovery", "· lines 3, 1",
                                     "A close fit.", "Written by your Claude client, through MCP (it reports claude-opus-5-5)", "its credential")
  end

  it "shows what the client saved as a draft: who wrote it, a tailored resume's changes, a revision's link" do
    first = second = nil
    assistant do
      first, = Drafts.save!(application, kind: "cover_letter", language: "English", body: "Dear Acme team,", resume_version: resume.version,
                                         lines_drawn_on: [ { line: 3, answers: "discovery" } ], reported_model: "claude-opus-5-5")
      second, = Drafts.save!(application, kind: "cover_letter", language: "English", body: "Dear Acme team, again.", resume_version: resume.version,
                                          revises: first.id)
      Drafts.save!(application, kind: "tailored_resume", language: "English", body: "Jordan Sample\n- Ran discovery.", resume_version: resume.version,
                                changes: [ { change: "Discovery first", lines: [ 3 ] } ])
    end

    get application_path(application)

    expect(response.body).to include("Written by your Claude client and saved through MCP (it reports claude-opus-5-5), on your subscription",
                                     "A revision of the", "href=\"#draft_#{first.id}\"", "Tailored resume", "What it changed: 1 change",
                                     "Discovery first", "Copy resume", "3 drafts")
    expect(second.revises).to eq(first)
  end

  it "deletes a review on the operator's word, its record keeping its counts" do
    review, = assistant do
      ResumeReviews.save!(application, language: "English", resume_version: resume.version, gaps: [ { asks: "Spanish", note: "Not shown." } ])
    end

    delete application_resume_review_path(application, review)

    expect(flash[:notice]).to eq("Resume review deleted.")
    expect(ResumeReview.count).to eq(0)
    expect(AuditEvent.find_by!(target_type: "ResumeReview", action: "destroy")).to have_attributes(actor: "human:operator")
  end
end
