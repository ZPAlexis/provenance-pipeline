require "rails_helper"

RSpec.describe "The audit log", type: :request do
  let!(:company) { create(:company, :resolved, name: "Acme", domain: "acme.example") }
  let!(:role) { create(:posting, company: company, role_title: "Sales Engineer") }

  # A check that closed the role, under its credential; the operator's rename; a suggestion refused.
  def history
    credential = as_agent("agent:verifier") do |run|
      role.update!(verification_state: "not_found", last_checked_at: Time.current, roles_listed_count: 12)
      AuditEvent.record_write!(role, actor: "agent:verifier", reasoning: "Not among the 12 roles listed.")
      run
    end
    company.update!(name: "Acme Inc", enrichment: { "Founded" => "2001" })
    AuditEvent.record_write!(company, actor: AuditEvent::OPERATOR, reasoning: "Its legal name.")
    create(:audit_event, actor: "agent:suggester", action: "denied", target: role, changes_made: { "tracking" => %w[suggested tracked] },
                         reasoning: "Denied: may not update a posting (tracking).")
    credential
  end

  it "shows every event in full: when, by whom under which credential, on what, the action, what changed, and why" do
    credential = history

    get audit_path

    expect(response).to have_http_status(:success)
    expect(response.body).to include("Audit log", "3 events.", "Everyone", "Operator", "Every agent", "Verifier", "Suggester",
                                     "Sales Engineer", "Acme Inc", "changed", "refused", "Not among the 12 roles listed.",
                                     "Its legal name.", agent_credential_path(credential))
    expect(response.body).to include("<code>verification_state</code> pending → not_found", "<code>name</code> Acme → Acme Inc",
                                     "<code>enrichment.Founded</code> <span class=\"muted\">—</span> → 2001")
  end

  it "narrows by who, kind, action, attribute and days, keeping the other filters in its links" do
    history

    get audit_path(who: "agent:verifier")
    expect(response.body).to include("1 event matches.")
    expect(response.body).to include("Not among the 12 roles listed.").and(not_include("Its legal name."))
    expect(response.body).to include('class="filter current"')

    get audit_path(kind: "company", act: "update")
    expect(response.body).to include("Its legal name.").and(not_include("Not among the 12 roles listed."))
    expect(response.body).to include(audit_path(who: "operator", kind: "company", act: "update").gsub("&", "&amp;"))

    get audit_path(act: "denied")
    expect(response.body).to include("Denied: may not update a posting").and(not_include("Its legal name."))

    get audit_path(attribute: "verification_state", from: Date.current.to_s, to: Date.current.to_s)
    expect(response.body).to include("Not among the 12 roles listed.").and(not_include("Denied: may not"))

    get audit_path(from: Date.tomorrow.to_s)
    expect(response.body).to include("No event matches.")
  end

  it "narrows to one record or one credential, naming it, with a way back to all" do
    credential = history

    get audit_path(record: role.id)
    expect(response.body).to include("On <a href=\"#{role_path(role)}\">Sales Engineer</a>", "(role)", "Every record")
      .and(not_include("Its legal name."))

    get audit_path(credential: credential.id)
    expect(response.body).to include("Written under", "Verifier's credential", "Any credential", "Not among the 12 roles listed.")
      .and(not_include("Denied: may not"))
  end

  # Found by the operator, 2026-10-28: an id in what changed is the only way to narrow, and an update rarely sets one.
  it "narrows to any event's record from its row, and names a review item's kind and company" do
    history
    beta = create(:company, name: "Beta", domain: "beta.example", resolution_status: "failed", resolution_failure: "blocked")
    create(:posting, company: beta, role_title: "Recruiter")
    create(:page_check, company: beta, purpose: "resolution", step: "path_probe", url: "https://beta.example/careers", run_id: "r0",
                        outcome: "blocked", reason: "robots_txt", checked_at: 1.day.ago)
    ReviewQueue.sync!(beta)
    item = beta.review_items.open.sole

    get audit_path
    expect(response.body).to include(">its events</a>", %(href="#{audit_path(record: role.id)}"), %(href="#{audit_path(record: company.id)}"),
                                     %(href="#{audit_path(record: item.id)}"), "No careers page at Beta")

    get audit_path(record: role.id)
    expect(response.body).not_to include(">its events</a>")
  end

  it "says why it can't apply a filter, and shows everything instead" do
    get audit_path(who: "nobody")
    expect(response).to redirect_to(audit_path)
    follow_redirect!
    expect(response.body).to include("Unknown actor &quot;nobody&quot;")

    get audit_path(record: "not-an-id")
    expect(flash[:alert]).to eq('Record is an id (a uuid), not "not-an-id"')
  end

  it "pages the events, newest first" do
    history
    stub_const("AuditLog::PER_PAGE", 2)

    get audit_path
    expect(response.body).to include("Showing 1–2.", "Page 1 of 2", "Older").and(not_include(">Newer<"))

    get audit_path(page: 2)
    expect(response.body).to include("Showing 3–3.", "Not among the 12 roles listed.", "Newer")
  end

  it "is linked from the pages that show history, already narrowed" do
    credential = history
    application = create(:application, posting: role, company: company)

    get role_path(role)
    expect(response.body).to include(audit_path(record: role.id))
    get company_path(company)
    expect(response.body).to include(audit_path(record: company.id))
    get agent_credential_path(credential)
    expect(response.body).to include(audit_path(credential: credential.id))
    get application_path(application)
    expect(response.body).to include(audit_path(record: application.id))
    get agents_path
    expect(response.body).to include(audit_path(act: "denied"), audit_path(who: "agent:verifier", from: 30.days.ago.to_date).gsub("&", "&amp;"))
    get root_path
    expect(response.body).to include(%(href="#{audit_path}"))
  end
end
