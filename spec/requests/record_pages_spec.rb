require "rails_helper"

# 4e step 10: the record's own pages and the About page, reorganized: each page's one line with the rest folded, and
# tabs where a page held stacked sections. Page views write nothing (page_views_spec).
RSpec.describe "The record's pages, reorganized", type: :request do
  let!(:company) { create(:company, :resolved, name: "Acme", domain: "acme.example") }
  let!(:role) { create(:posting, :verified_live, company: company, role_title: "Sales Engineer", tracking: "tracked") }

  def tabs(body) = body.scan(/role="tab"[^>]*>([^<]+)</).flatten.map(&:strip)

  it "shows the Agents page in tabs: yours alone first, each agent's scopes as chips, its full list in a fold" do
    get agents_path

    expect(tabs(response.body)).to eq([ "Who may write what", "Credentials", "Refused writes" ])
    expect(response.body.index("Yours alone")).to be < response.body.index("Verifier")
    expect(response.body).to include(%(<details class="scope-fold">), "What its 2 scopes allow", %(class="scope" title=))
    expect(response.body).to include(%(href="/agents?actor=agent%3Averifier#credentials"))
  end

  it "shows Analytics in three tabs, its explanation folded" do
    get analytics_path

    expect(tabs(response.body)).to eq([ "Pipeline", "The watch", "The agents" ])
    expect(response.body).to include("How this works", %(<section id="agents" class="tab-panel"))
  end

  it "shows the dashboard's two tables as tabs, eight verdicts at most" do
    get root_path

    expect(tabs(response.body)).to eq([ "Checks you asked for", "Verdict changes" ])
    expect(response.body).to include(%(<div class="dash-groups">), "Tracked companies' lists")
    expect(Overview::RECENT_CHANGES).to eq(8)
  end

  # 4e step 11: What changed is the audit log's Check results; the page's address leads there.
  it "shows what a check found in the audit log's Check results, what needs you marked" do
    create(:check_run, kind: "all", company: nil, status: "done", started_at: 1.hour.ago, finished_at: 10.minutes.ago, total: 1)
    as_agent("agent:verifier") do
      role.update!(verification_state: "not_found", last_checked_at: Time.current)
      AuditEvent.record_write!(role, actor: "agent:verifier", reasoning: "Not among the roles listed.")
    end
    # Its careers page not found: a question for you.
    ReviewQueue.sync!(create(:company, name: "Contoso", domain: "contoso.example", resolution_status: "failed", resolution_failure: "not_found"))

    get audit_path(view: "checks")

    expect(tabs(response.body)).to eq([ "Every write", "Check results" ])
    expect(response.body).to include(%(id="checks-tab" role="tab" aria-controls="checks" aria-selected="true"))
    expect(response.body).to include("No longer listed", "Review question", %(<span class="badge needs">Needs you</span>), "Needs you (1)")

    get audit_path(view: "checks", result: "needs_you")
    expect(response.body.scan(%(<span class="badge needs">)).size).to eq(1)
    expect(response.body).not_to include(%(<span class="badge gone">No longer listed</span>))

    get changes_path(from: "week")
    expect(response).to redirect_to(audit_path(view: "checks", since: "week"))
    expect(response).to have_http_status(:moved_permanently)
  end

  it "says nothing changed, when nothing did, and leaves What changed out of the Record menu" do
    get audit_path(view: "checks")

    expect(response.body).to include("Nothing changed since then.").and(not_include(">What changed</a>"))
  end

  it "shows About in four steps and a section for each, naming your AI assistant" do
    get about_path

    expect(response.body).to include(%(<ol class="steps">), %(<section id="watch">), %(<section id="find">), %(<section id="apply">),
                                     %(<section id="assistant">), %(<section id="govern">), "Your own AI assistant (Claude or another MCP client")
    expect(response.body).not_to include("Claude client")
  end
end
