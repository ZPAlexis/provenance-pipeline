require "rails_helper"

RSpec.describe "Companies", type: :request do
  let(:company) { create(:company, :resolved, name: "Acme") }

  it "lists watched companies with their roles still listed, and candidates on their own tab" do
    create(:posting, :verified_live, company: company)
    create(:company, :resolution_candidate, name: "Maybe Corp")

    get companies_path
    expect(response).to have_http_status(:success)
    expect(response.body).to include("Acme")
    expect(response.body).not_to include("Maybe Corp")

    get companies_path(view: "candidates")
    expect(response.body).to include("Maybe Corp")
  end

  it "shows a company's page, board, roles, recent checks, and recent changes" do
    company.update!(board_vendor: "ashby", board_token: "acme", board_overlap: 0.97, board_evidence: "Lists the roles.",
                    board_confirmed_at: 1.day.ago)
    create(:posting, company: company, role_title: "RevOps Engineer")
    create(:page_check, company: company, purpose: "verification", read_via: "ats_api:ashby", listing_count: 40)
    AuditEvent.record!(actor: "agent:verifier", action: "update", target: company,
                       changes_made: { "board_vendor" => [ nil, "ashby" ] }, reasoning: "A free board lists the same roles.")

    get company_path(company)

    expect(response).to have_http_status(:success)
    expect(response.body).to include("ashby/acme", "Lists the roles.", "read in place of the page", "RevOps Engineer",
                                     "Ashby API", "A free board lists the same roles.")
  end
end
