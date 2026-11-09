require "rails_helper"

# A page view reads the record and writes nothing to it (review pass R5). A check left active past its time shows as
# cut off, its row untouched until the next check starts.
RSpec.describe "Page views", type: :request do
  let!(:company) { create(:company, :resolved, name: "Acme", domain: "acme.example") }
  let!(:role) { create(:posting, :verified_live, company: company, role_title: "Sales Engineer", tracking: "tracked") }
  let!(:application) { create(:application, posting: role) }
  let!(:lost) { create(:check_run, :role, company: company, posting: role, status: "running", started_at: 2.hours.ago, updated_at: 2.hours.ago) }
  let!(:lost_company) { create(:check_run, company: company, status: "queued", updated_at: 2.hours.ago) }
  let!(:lost_everything) { create(:check_run, kind: "all", company: nil, status: "running", started_at: 5.hours.ago, updated_at: 5.hours.ago) }
  # A company the operator's own client proposed (4b), the company preferences, and a review of each.
  let!(:proposal) { create(:company, :proposed, name: "Contoso", domain: "contoso.example") }
  let!(:profile) { SearchProfile.create!(titles: [ "Sales Engineer" ], places: [ "Brazil" ], company_models: %w[b2b]) }
  let!(:reviews) { [ create(:company_review, company: company, stage: "series_b", industries: [ "Fintech" ]), create(:company_review, company: proposal) ] }

  # The statements that would change the record, made while the block runs.
  def writes
    seen = []
    record = ->(*, payload) { seen << payload[:sql] if payload[:sql].match?(/\A\s*(INSERT|UPDATE|DELETE|TRUNCATE)\b/i) }
    ActiveSupport::Notifications.subscribed(record, "sql.active_record") { yield }
    seen
  end

  it "writes nothing to the record, on any page" do
    credential, = AgentCredential.issue!(actor: "agent:verifier", scopes: %w[postings:verify], purpose: "verifier:verify",
                                         ttl: 1.hour, issued_by: AuditEvent::OPERATOR)
    pages = [ root_path, check_all_path, changes_path, audit_path, analytics_path, roles_path, role_path(role),
              companies_path, company_path(company), company_path(proposal), companies_path(tab: "all"), companies_path(tab: "suggested"),
              companies_path(fit: "70", sort: "fit", stage: "series_b", industry: "fintech"), companies_path(fit: "stale"),
              applications_path, application_path(application), review_path,
              agents_path, agent_credential_path(credential), profile_path, about_path, check_run_path(lost, poll: 1) ]

    pages.each do |page|
      expect(writes { get page }).to be_empty, "#{page} wrote to the record"
      expect(response).to have_http_status(:success), "#{page}: #{response.status}"
    end
    expect([ lost, lost_company, lost_everything ].map { |run| run.reload.status }).to eq(%w[running queued running])
  end

  it "shows a check left active past its time as cut off, and polls it no more" do
    get role_path(role)
    expect(response.body).to include("Didn't finish", "Cut off: the server stopped", "Last heard from")
    expect(response.body).not_to include(check_run_path(lost, poll: 1))

    get company_path(company)
    expect(response.body).to include("Cut off: the server stopped").and not_include("Waiting for the check before it to finish")

    get root_path
    expect(response.body).to include("Didn't finish").and not_include("Checking…")

    get check_all_path
    expect(response.body).to include("Cut off: the server stopped", "Check everything")

    get check_run_path(lost, poll: 1) # a page left open as its time ran out reloads once, then stops
    expect(response.body).to include('data-controller="refresh"').and not_include('data-controller="poll"')
  end

  it "says so on the run's row once the next check starts, which it no longer blocks" do
    expect { post check_runs_path, params: { posting_id: role.id } }.to have_enqueued_job(CheckNowJob)

    expect(lost.reload).to have_attributes(status: "failed", error: CheckRun::CUT_OFF, finished_at: be_present)
    expect(lost_company.reload.status).to eq("failed")
    expect(CheckRun.where(kind: "role").active.sole).to have_attributes(posting: role, status: "queued")
  end

  it "shows a company proposed to the operator as a proposal, with Track it and Archive, its board being read" do
    create(:check_run, company: proposal, status: "running", started_at: 1.minute.ago, request: { "read" => "board" }, ceiling_usd: 0)

    get company_path(proposal)

    expect(response.body).to include("Proposed by your own Claude client: not watched or checked until you track it.",
                                     "Track it", "Why track it?", "Declined for good: it is never proposed again.",
                                     "Reading the board it was proposed with, free")
    get companies_path(tab: "all")
    expect(response.body).to include("Contoso", ">suggested<")
  end
end
