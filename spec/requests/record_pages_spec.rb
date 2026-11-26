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

  # 4e step 12: the dashboard and Analytics, one page.
  it "shows the dashboard in three tabs, now on top and how it has gone under it, its explanation folded" do
    get root_path

    expect(tabs(response.body)).to eq([ "Pipeline", "The watch", "Agents" ])
    expect(response.body).to include("How this works", %(<section id="agents" class="tab-panel"), ">Runs</h3>", "To review")
    expect(response.body.scan(%(<h3>How it has gone</h3>)).size).to eq(3)
    expect(response.body).not_to include("Verdict changes", "Checks you asked for")
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

  # 4e step 13: the app's name and icon in a row of their own, then its pages as tabs, the work left and the setup right.
  it "lays the top bar out as tabs: the work on the left, the setup on the right, the page you are on selected" do
    get audit_path

    nav = response.body[%r{<nav id="site-tabs".*?</nav>}m]
    left, right = nav.scan(%r{<div class="tabs-side">(.*?)</div>}m).flatten.map { |side| side.scan(%r{<a [^>]*>([^<]+)}).flatten.map(&:strip) }
    expect(left).to eq([ "Dashboard", "Pipeline", "Roles", "Companies", "Review", "Audit log" ])
    expect(right).to eq([ "Profile", "Agents", "About" ])
    expect(nav).to include(%(<a class="current" aria-current="page" href="/audit">Audit log</a>))
    header = response.body[%r{<header class="site-header".*?</header>}m]
    expect(header).to include(%(class="brand-icon"), "app-logo-icon", %(data-action="nav#toggle")).and(not_include("Record"))
  end

  it "links an application to its role's own page and its company's site and careers page" do
    role.update!(job_url: "https://job-boards.greenhouse.io/acme/jobs/4012345")
    application = create(:application, posting: role)

    get application_path(application)

    expect(response.body).to include("Its own page", %(href="https://job-boards.greenhouse.io/acme/jobs/4012345"), "Its company",
                                     %(href="https://acme.example"), %(href="#{company.careers_page_url}"), "its careers page")
    # Its own page in a few characters, so the line never breaks; then its role page, in place of the Description's link.
    expect(response.body).to include(%(class="nowrap" href="https://job-boards.greenhouse.io/acme/jobs/4012345">job-boards.greenhouse.io/…</a>),
                                     %(<a href="#{role_path(role)}">its role page</a>)).and(not_include("read it on the role"))
  end

  it "shows About in four steps and a section for each, naming your AI assistant" do
    get about_path

    # 4e step 13: each part a tab, after the opening and its four steps.
    expect(tabs(response.body)).to eq([ "Watching", "Finding", "Applying", "Governance", "AI assistant (MCP)" ])
    expect(response.body).to include(%(<ol class="steps">), %(<a href="#find">), %(<section id="assistant" class="tab-panel"),
                                     "Your own AI assistant (Claude or another MCP client")
    expect(response.body).not_to include("Claude client")
  end
end
