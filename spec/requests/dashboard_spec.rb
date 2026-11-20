require "rails_helper"

RSpec.describe "Dashboard", type: :request do
  let(:company) { create(:company, :resolved, name: "Acme") }

  it "counts tracked roles by answer and shows recent verdict changes with who made them" do
    role = create(:posting, :verified_live, company: company, role_title: "RevOps Engineer")
    create(:posting, company: company, tracking: "dismissed")
    role.update!(verification_state: "not_found")
    Authority.unchecked do # history, as the agent wrote it
      AuditEvent.record_write!(role, actor: "agent:verifier", reasoning: "None of the 12 roles on the page is it.")
    end
    create(:llm_call, cost_usd: 0.25)

    get root_path

    expect(response).to have_http_status(:success)
    body = response.body
    expect(body).to include("No longer listed", "Archived", "Companies watched", "$0.25")
    expect(body).to include("RevOps Engineer", "Still listed → No longer listed", "Verifier", "None of the 12 roles on the page is it.")
  end

  # A run with no company (4d: a read of the operator's links) is listed by what it read, never by a company.
  it "lists a read of the operator's links among the recent checks" do
    CheckRun.start_links!.update!(status: "done", answer: "read", summary: "GitHub: 8 pages; Portfolio: 2 pages", cost_usd: 0,
                                  started_at: 1.minute.ago, finished_at: Time.current)

    get root_path

    expect(response).to have_http_status(:success)
    expect(response.body).to include(">Your links</a>", "(read free)", "GitHub: 8 pages; Portfolio: 2 pages")
  end

  it "says so when no verdict has changed yet" do
    get root_path

    expect(response.body).to include("No verdict has changed yet.")
  end
end
