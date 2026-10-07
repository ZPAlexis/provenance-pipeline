require "rails_helper"

RSpec.describe "Check now", type: :request do
  let(:company) { create(:company, :resolved, name: "Acme") }
  let(:role) { create(:posting, :verified_live, company: company, role_title: "RevOps Engineer") }

  it "queues a check of one role and goes to the role's page, where it shows" do
    expect { post check_runs_path, params: { posting_id: role.id } }.to have_enqueued_job(CheckNowJob)

    run = CheckRun.sole
    expect(run).to have_attributes(kind: "role", posting: role, company: company, status: "queued",
                                   requested_by: "human:operator")
    expect(response).to redirect_to(role_path(role))
    follow_redirect!
    expect(response.body).to include("Waiting for the check before it to finish", "turbo-frame", check_run_path(run, poll: 1))
  end

  it "queues a check of a company's careers page" do
    expect { post check_runs_path, params: { company_id: company.id } }.to have_enqueued_job(CheckNowJob)

    expect(CheckRun.sole).to have_attributes(kind: "company", posting: nil)
    expect(response).to redirect_to(company_path(company))
  end

  it "never queues a second check of something already being checked" do
    post check_runs_path, params: { posting_id: role.id }

    expect { post check_runs_path, params: { posting_id: role.id } }.not_to have_enqueued_job(CheckNowJob)
    expect(CheckRun.count).to eq(1)
  end

  it "refuses a dismissed role, saying why" do
    role.update!(tracking: "dismissed")

    expect { post check_runs_path, params: { posting_id: role.id } }.not_to have_enqueued_job(CheckNowJob)
    follow_redirect!
    expect(response.body).to include("is dismissed: track it again to check it.")
  end

  # A check that can spend asks first, saying what it could cost.
  it "asks before a check that could read a page with the LLM, and not before a free one" do
    check = create(:page_check, company: company, purpose: "verification", run_id: "r1")
    create(:llm_call, page_check: check, cost_usd: 0.05)

    get role_path(role)
    expect(response.body).to include("data-turbo-confirm", "at most $0.050")

    company.update!(board_vendor: "ashby", board_token: "acme", board_overlap: 0.95, board_evidence: "Lists the roles.",
                    board_confirmed_at: 1.day.ago)
    get role_path(role)
    expect(response.body).not_to include("data-turbo-confirm")
  end

  describe "polling" do
    it "answers with the run's frame, which keeps polling while it runs" do
      run = create(:check_run, :role, company: company, status: "running", started_at: 10.seconds.ago)

      get check_run_path(run, poll: 1)

      expect(response.body).to include(%(id="#{ActionView::RecordIdentifier.dom_id(run)}"), 'data-controller="poll"', "Checking")
      # Turbo refuses a reply whose frame points at the address it came from: only the page's frame polls.
      expect(response.body).not_to match(/<turbo-frame[^>]*src=/)

      get role_path(run.posting)
      expect(response.body).to match(/<turbo-frame[^>]*src="#{Regexp.escape(check_run_path(run, poll: 1))}"/)
    end

    it "tells the page to reload once the run it polled is done" do
      run = create(:check_run, :role, company: company, status: "done", answer: "verified_live", cost_usd: 0,
                                      summary: "Its own page is up and shows the role.", finished_at: Time.current)

      get check_run_path(run, poll: 1)
      expect(response.body).to include('data-controller="refresh"', "Still listed", "Its own page is up")

      get role_path(run.posting)
      expect(response.body).not_to include('data-controller="refresh"')
    end
  end

  it "lists the latest checks on the dashboard" do
    create(:check_run, :role, company: company, status: "done", answer: "not_found", cost_usd: 0.004)

    get root_path

    expect(response.body).to include("Recent checks you asked for", "No longer listed", "$0.004")
  end
end
