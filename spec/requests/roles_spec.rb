require "rails_helper"

RSpec.describe "Roles", type: :request do
  let(:company) { create(:company, :resolved, name: "Acme") }

  describe "GET /roles" do
    it "lists tracked roles grouped by answer, never the dismissed ones" do
      create(:posting, :verified_live, company: company, role_title: "RevOps Engineer", job_url: "https://acme.example/jobs/1")
      create(:posting, company: company, role_title: "Designer")
      create(:posting, company: company, role_title: "Office Manager", tracking: "dismissed")

      get roles_path

      expect(response).to have_http_status(:success)
      expect(response.body).to include("RevOps Engineer", "Still listed", "Designer", "No answer yet", "acme.example/jobs/1")
      expect(response.body).not_to include("Office Manager")
    end

    it "shows the dismissed tab, and an empty suggested one with what it is for" do
      create(:posting, company: company, role_title: "Office Manager", tracking: "dismissed")

      get roles_path(tab: "dismissed")
      expect(response.body).to include("Office Manager")

      get roles_path(tab: "suggested")
      expect(response.body).to include("Suggestions arrive with the search profile")
    end
  end

  describe "GET /roles/:id" do
    it "shows the role's answer, its history with who and why, and the checks that looked for it" do
      role = create(:posting, :verified_live, company: company, role_title: "RevOps Engineer")
      AuditEvent.record!(actor: "human:operator", action: "update", target: role,
                         changes_made: { "tracking" => [ "suggested", "tracked" ] }, reasoning: "Tracked by hand. Fits.")
      create(:page_check, company: company, purpose: "verification", checked_at: 1.day.ago,
                          matches: [ { "posting_id" => role.id, "verdict" => "verified_live", "method" => "exact",
                                       "reasoning" => 'The page lists "RevOps Engineer".' } ])

      get role_path(role)

      expect(response).to have_http_status(:success)
      expect(response.body).to include("RevOps Engineer", "Acme", "Still listed", "suggested → tracked", "Operator",
                                       "Tracked by hand. Fits.", "The page lists &quot;RevOps Engineer&quot;.")
    end

    it "goes back with a note for a role that does not exist" do
      get role_path(SecureRandom.uuid)

      expect(response).to redirect_to(root_path)
    end
  end
end
