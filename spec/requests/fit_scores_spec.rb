require "rails_helper"

# Weighing roles' fit from the pages (2f step 2): a role's page, the Roles page's fit column, filters and sort, and
# weighing the unscored in the background with what it could cost asked first.
RSpec.describe "Fit scores", type: :request do
  include ActiveJob::TestHelper

  let!(:company) { create(:company, :resolved, name: "Acme", domain: "acme.example") }
  let!(:role) { create(:posting, :verified_live, company: company, role_title: "Sales Engineer", job_url: "https://acme.example/jobs/1") }
  let!(:profile) { SearchProfile.create!(titles: [ "Sales Engineer" ]) }

  def keep_resume(text = "Jordan Sample\nSales engineer, eight years.\n- Ran discovery for 35 accounts a year.") = Resumes.keep!(profile, text: text)

  def describe_role(posting = role, text = "Discovery. Spanish required.")
    posting.role_descriptions.create!(text: text, content_hash: Resume.digest(text), read_via: "render", url: posting.job_url, run_id: "r1",
                                      first_read_at: 1.day.ago, last_read_at: 1.day.ago)
  end

  # A score as the fit scorer leaves one, its call included.
  def weighed(posting = role, score: 72, **fields)
    resume = profile.resumes.newest_first.first
    description = posting.role_descriptions.newest_first.first
    call = LlmCall.create!(run_id: "20261026T120000Z-fit", purpose: "fit", model: "claude-haiku-4-5-20251001", settings: {},
                           prompt_version: "f1", input_tokens: 4_000, output_tokens: 600, cost_usd: 0.007, called_at: Time.current)
    posting.fit_scores.create!(score: score, level: "Mid-level; the resume shows eight years", why: "Strong on discovery; Spanish is missing.",
                               matches: [ { "point" => "Discovery at volume", "lines" => [ { "line" => 3, "text" => "- Ran discovery for 35 accounts a year." } ] } ],
                               gaps: [ { "asks" => "Spanish", "note" => "Not shown." } ], resume: resume, resume_hash: resume.content_hash,
                               role_description: description, description_hash: description.content_hash, written_by: "agent:fit_scorer",
                               llm_call: call, run_id: call.run_id, **fields)
  end

  describe "a role's page" do
    it "says what weighing needs: a resume, and a description or a page to read one from" do
      get role_path(role)
      expect(response.body).to include("Weighing its fit needs your resume").and(not_include("Weigh its fit"))

      keep_resume
      pageless = create(:posting, company: company, role_title: "Account Executive")
      get role_path(pageless)
      expect(response.body).to include("No description to weigh it from")

      get role_path(role)
      expect(response.body).to include("Weigh its fit", "its description (read first, free)", "about $0.007")
    end

    it "weighs it in the background as asked, one weighing at a time, refusing a role with nothing to weigh" do
      keep_resume
      describe_role

      expect { post fit_scores_path, params: { posting_id: role.id } }.to have_enqueued_job(CheckNowJob)
      expect(response).to redirect_to(role_path(role, anchor: "fit"))
      expect(CheckRun.sole).to have_attributes(kind: "fit", posting: role, company: company, request: { "posting_ids" => [ role.id ] })

      get role_path(role)
      expect(response.body).to include("Waiting for the check before it to finish").and(not_include("Weigh its fit"))

      pageless = create(:posting, company: company, role_title: "Account Executive")
      post fit_scores_path, params: { posting_id: pageless.id }
      expect(flash[:alert]).to eq("Not weighed: Account Executive has no description to weigh, nor a page of its own to read one from.")
      expect(CheckRun.count).to eq(1)
    end

    it "shows its newest score, why, the level, the matches by resume line and the gaps, marked stale once the resume changes" do
      keep_resume
      describe_role
      weighed(score: 60)
      weighed

      get role_path(role)
      expect(response.body).to include(">72<", "Strong on discovery; Spanish is missing.", "Mid-level; the resume shows eight years",
                                       "Discovery at volume", "[3] - Ran discovery for 35 accounts a year.", "Spanish", "Not shown.",
                                       "by the fit scorer with claude-haiku-4-5-20251001 for $0.007", "Before: 60 on", "Weigh it again")
      expect(response.body).not_to include("changed since it was weighed")

      keep_resume("Jordan Sample\nA newer resume.")
      get role_path(role)
      expect(response.body).to include("The resume changed since it was weighed")
    end
  end

  describe "the Roles page" do
    let!(:other) { create(:posting, :verified_live, company: company, role_title: "Solutions Engineer", job_url: "https://acme.example/jobs/2") }
    let!(:third) { create(:posting, company: company, role_title: "Account Executive") }

    before do
      keep_resume
      describe_role
      describe_role(other, "Back-end Python engineering.")
    end

    it "shows each role's fit, filters by it, and sorts by it, best first" do
      weighed(score: 88)
      weighed(other, score: 41)

      get roles_path
      expect(response.body).to include(">88<", ">41<", "Fit:", "85 and up", "Not weighed")

      get roles_path(fit: "70")
      expect(response.body).to include("Sales Engineer</a>").and(not_include("Solutions Engineer</a>", "Account Executive</a>"))
      get roles_path(fit: "none")
      expect(response.body).to include("Account Executive</a>").and(not_include(">88<"))

      get roles_path(sort: "fit")
      body = response.body
      expect(body.index("Sales Engineer</a>")).to be < body.index("Solutions Engineer</a>")
      expect(body.index("Solutions Engineer</a>")).to be < body.index("Account Executive</a>")
      expect(body).to include("Fit ↓")
    end

    it "offers to weigh the unscored with their description, with the cost asked first, and runs them as one batch" do
      weighed(score: 88)

      get roles_path
      expect(response.body).to include("Weigh 1 unscored role", "Haiku 4.5 weighs 1 role against your resume, one call each: about $0.007")

      expect { post fit_scores_path }.to have_enqueued_job(CheckNowJob)
      expect(response).to redirect_to(roles_path(sort: "fit"))
      expect(CheckRun.sole).to have_attributes(kind: "fit", posting: nil, company: nil, request: { "posting_ids" => [ other.id ] })

      get roles_path
      expect(response.body).to include("Waiting for the check before it to finish").and(not_include("Weigh 1 unscored role"))
    end

    it "marks a stale score and counts it among the unscored, and says when there is nothing to weigh" do
      weighed(score: 88)
      weighed(other, score: 41)
      get roles_path
      expect(response.body).not_to include("unscored role")
      post fit_scores_path
      expect(flash[:alert]).to eq("Not weighed: every role offered has a current score, or no description to weigh.")

      keep_resume("Jordan Sample\nA newer resume.")
      get roles_path
      expect(response.body).to include("stale", "Weigh 2 unscored roles")
    end
  end

  it "lists fit runs among the recent checks on the dashboard" do
    create(:check_run, kind: "fit", company: company, posting: role, status: "done", answer: "weighed", summary: "Weighed: 72.",
                       cost_usd: 0.007, request: { "posting_ids" => [ role.id ] })
    create(:check_run, kind: "fit", company: nil, status: "done", answer: "weighed", summary: "Weighed 2 roles.", cost_usd: 0.014,
                       request: { "posting_ids" => [ role.id, "x" ] })

    get root_path

    expect(response.body).to include("(its fit)", "Roles by fit", "(the fit of 2 roles)", "Weighed")
  end
end
