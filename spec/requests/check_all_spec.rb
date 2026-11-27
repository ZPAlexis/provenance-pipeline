require "rails_helper"

# "Check all tracked companies" (1.4's "check everything"; on the Roles page and over every tracked company since 4e):
# its plan and ceiling asked first, how old the lists are, run in the background; the dashboard says how old they are.
RSpec.describe "Check all tracked companies", type: :request do
  include ActiveJob::TestHelper

  let!(:company) { create(:company, :resolved, name: "Acme", domain: "acme.example") }

  it "has its place on the Roles page, filled in after the page loads, and the dashboard says how old the lists are" do
    get roles_path
    expect(response.body).to include(%(src="#{check_all_path}"))

    get root_path
    expect(response.body).to include("Of 1 tracked company, 0 lists last read more than", "14 days", "and", "1 never",
                                     "role search reads these lists as they were last read", %(<a href="/roles">Check all tracked companies</a>))
      .and not_include(%(src="#{check_all_path}"))
  end

  it "shows the plan and the most it could cost, a company with no role read too, and asks first" do
    create(:posting, company: company, role_title: "Sales Engineer")
    create(:company, :resolved, name: "Contoso", domain: "contoso.example") # no role yet: read for new ones
    read = create(:page_check, company: company, purpose: "verification", step: nil, url: company.careers_page_url, checked_at: 20.days.ago)
    create(:llm_call, page_check: read, cost_usd: 0.02)

    get check_all_path

    expect(response.body).to include("Reads the careers pages of 2 companies (1 with no role of yours yet)", "confirms the 1 role you track",
                                     "finds new ones that fit your profile", "about $0.04", "1 page never read, priced at an average list",
                                     "Check all tracked companies",
                                     "Lists last read: 1 more than 14 days ago, the oldest", "1 never", "data-turbo-confirm")
  end

  # 4f: a free check beside it, no AI anywhere; the only one with no API key set; and the pages a free check left unread.
  it "offers a free check beside it, starts one as asked, and lists the pages it left unread" do
    get check_all_path
    expect(response.body).to include("Check all tracked companies", "Check free", "up to\n            1 company' pages", "left for your AI assistant")

    expect { post check_all_path, params: { mode: "free" } }.to have_enqueued_job(CheckNowJob)
    expect(CheckRun.sole).to have_attributes(request: { "mode" => "free" }, ceiling_usd: 0)
    expect(flash[:notice]).to start_with("A free check of all tracked companies")

    CheckRun.sole.update!(status: "done", finished_at: Time.current, summary: "1 company read.")
    create(:page_check, company: company, purpose: "verification", step: nil, url: company.careers_page_url, outcome: "error",
                        reason: "needs_reading", read_via: "render", checked_at: 1.hour.ago)
    get check_all_path
    expect(response.body).to include("1 page left unread by a free check: it needs", "acme.example/…", "left <time", "about 1 hour ago</time>")
  end

  it "offers only the free check when no API key is set, and runs every check free" do
    without_api_key
    get check_all_path
    expect(response.body).to include("Free: no API key is set").and not_include("Check free", "data-turbo-confirm=\"Check all tracked companies:")

    post check_all_path
    expect(CheckRun.sole).to have_attributes(request: { "mode" => "free" }, ceiling_usd: 0)
  end

  it "says when there is nothing to check" do
    company.update!(tracking: "dismissed")
    get check_all_path

    expect(response.body).to include("No company is tracked with a careers page to read yet")
  end

  it "starts it in the background, one at a time, back to the Roles page, and follows it while it runs" do
    expect { post check_all_path }.to have_enqueued_job(CheckNowJob).exactly(:once)
    expect { post check_all_path }.not_to have_enqueued_job(CheckNowJob)
    expect(response).to redirect_to(roles_path)

    CheckRun.sole.update!(status: "running", started_at: Time.current, run_id: "20261014T120000Z-verify", total: 1)
    get check_all_path

    expect(response.body).to include("Checking all tracked companies:", "0 of 1 company read")
  end
end
