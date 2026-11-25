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

  it "shows What changed in tabs, what needs you first, only those that hold something" do
    create(:check_run, kind: "all", company: nil, status: "done", started_at: 1.hour.ago, finished_at: 10.minutes.ago, total: 1)
    as_agent("agent:verifier") do
      role.update!(verification_state: "not_found", last_checked_at: Time.current)
      AuditEvent.record_write!(role, actor: "agent:verifier", reasoning: "Not among the roles listed.")
    end
    # Its careers page not found: a question for you.
    ReviewQueue.sync!(create(:company, name: "Contoso", domain: "contoso.example", resolution_status: "failed", resolution_failure: "not_found"))

    get changes_path

    expect(tabs(response.body).first(2)).to eq([ "Needs you", "Listings" ])
    expect(tabs(response.body)).not_to include("Suggestions", "Refused writes")
    expect(response.body).to include(%(id="new-review-questions"), %(id="no-longer-listed"))

    get changes_path(from: "week")
    expect(response.body).to include("What changed since a check of all tracked companies")
  end

  it "says nothing changed, with no tabs, when nothing did" do
    get changes_path

    expect(response.body).to include("Nothing changed since then.")
    expect(tabs(response.body)).to be_empty
  end

  it "shows About in four steps and a section for each, naming your AI assistant" do
    get about_path

    expect(response.body).to include(%(<ol class="steps">), %(<section id="watch">), %(<section id="find">), %(<section id="apply">),
                                     %(<section id="assistant">), %(<section id="govern">), "Your own AI assistant (Claude or another MCP client")
    expect(response.body).not_to include("Claude client")
  end
end
