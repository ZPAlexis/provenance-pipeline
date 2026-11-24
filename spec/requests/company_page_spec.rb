require "rails_helper"

# A company's page (4e step 6): its header (its tracking, fit, roles and application, with Check now and Track or
# Archive), its careers page in view, then tabs with its roles first; its history holds what was saved under it, the AI
# assistant's company review and a contact deleted since included.
RSpec.describe "A company's page", type: :request do
  let!(:company) { create(:company, :resolved, name: "Acme", domain: "acme.example") }
  let!(:role) { create(:posting, :verified_live, company: company, role_title: "Sales Engineer", tracking: "tracked") }

  it "opens on its roles, its fit, roles and application in the header, its careers page above the tabs" do
    create(:company_review, company: company, score: 72)
    application = create(:application, posting: role, stage: "applied")
    get company_path(company)

    body = response.body
    expect(body).to include("1 role tracked, 1 still listed", ">72<", application_path(application), "Check now",
                            "close or withdraw it before archiving the company") # an open application holds Archive back
    expect(body).to include(%(id="roles-tab" role="tab" aria-controls="roles" aria-selected="true"))
    expect(body.index(">Careers page</dt>")).to be < body.index(%(role="tablist"))
    expect(body).to include("How it was found", "Recent checks", "Rename it", "Set its careers page by hand")
  end

  it "keeps in its history the review the AI assistant saved and a contact deleted since" do
    Authority.unchecked do # as the AI assistant saved it through MCP
      review = create(:company_review, company: company, score: 72)
      AuditEvent.record!(actor: "agent:assistant", action: "create", target: review, reasoning: "Saved through MCP: 72.",
                         changes_made: { "score" => [ nil, 72 ] })
    end
    contact = Contacts.save!(company, { name: "Ana Lima", kind: "recruiter" })
    Contacts.delete!(contact)
    get company_path(company)

    expect(response.body).to include("company review: 72", "Saved through MCP: 72.", "contact added", "contact deleted")
  end
end
