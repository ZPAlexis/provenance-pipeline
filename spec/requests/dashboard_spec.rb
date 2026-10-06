require "rails_helper"

RSpec.describe "Dashboard", type: :request do
  let(:company) { create(:company, :resolved, name: "Acme") }

  it "counts tracked roles by answer and shows recent verdict changes with who made them" do
    role = create(:posting, :verified_live, company: company, role_title: "RevOps Engineer")
    create(:posting, company: company, tracking: "dismissed")
    role.update!(verification_state: "not_found")
    AuditEvent.record_write!(role, actor: "agent:verifier", reasoning: "None of the 12 roles on the page is it.")
    create(:llm_call, cost_usd: 0.25)

    get root_path

    expect(response).to have_http_status(:success)
    body = response.body
    expect(body).to include("No longer listed", "Dismissed", "Companies watched", "$0.25")
    expect(body).to include("RevOps Engineer", "Still listed → No longer listed", "Verifier", "None of the 12 roles on the page is it.")
  end

  it "says so when no verdict has changed yet" do
    get root_path

    expect(response.body).to include("No verdict has changed yet.")
  end
end
