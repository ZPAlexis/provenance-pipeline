require "rails_helper"

RSpec.describe "Check everything", type: :request do
  include ActiveJob::TestHelper

  let!(:company) { create(:company, :resolved, name: "Acme", domain: "acme.example") }

  it "has its place on the dashboard, filled in after the page loads" do
    get root_path

    expect(response.body).to include("Check everything", %(src="#{check_all_path}"))
  end

  it "shows the plan and the most it could cost, and asks first" do
    create(:posting, company: company, role_title: "Sales Engineer")
    read = create(:page_check, company: company, purpose: "verification", step: nil, url: company.careers_page_url)
    create(:llm_call, page_check: read, cost_usd: 0.02)

    get check_all_path

    expect(response.body).to include("Reads the careers pages of 1 company, for 1 role", "At most $0.02", "Check everything",
                                     "data-turbo-confirm")
  end

  it "says when there is nothing to check" do
    get check_all_path

    expect(response.body).to include("No watched company has a role on record yet")
  end

  it "starts it in the background, one at a time, and follows it while it runs" do
    create(:posting, company: company)

    expect { post check_all_path }.to have_enqueued_job(CheckNowJob).exactly(:once)
    expect { post check_all_path }.not_to have_enqueued_job(CheckNowJob)
    expect(response).to redirect_to(root_path)

    CheckRun.sole.update!(status: "running", started_at: Time.current, run_id: "20261014T120000Z-verify", total: 1)
    get check_all_path

    expect(response.body).to include("Checking everything:", "0 of 1 company read")
  end
end
