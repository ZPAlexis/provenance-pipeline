require "rails_helper"

RSpec.describe "Roles", type: :request do
  let(:company) { create(:company, :resolved, name: "Acme") }

  describe "GET /roles" do
    it "lists tracked roles in one table, never the dismissed ones" do
      create(:posting, :verified_live, company: company, role_title: "RevOps Engineer", job_url: "https://acme.example/jobs/1")
      create(:posting, company: company, role_title: "Designer")
      create(:posting, company: company, role_title: "Office Manager", tracking: "dismissed")

      get roles_path

      expect(response).to have_http_status(:success)
      expect(response.body).to include("RevOps Engineer", "Still listed", "Designer", "No answer yet", "https://acme.example/jobs/1")
      expect(response.body).not_to include("Office Manager")
    end

    it "narrows a tab to one answer, with each answer's count" do
      create(:posting, :verified_live, company: company, role_title: "RevOps Engineer")
      create(:posting, :credible_negative, company: company, role_title: "Data Engineer")
      create(:posting, :credible_negative, company: company, role_title: "Old Role", tracking: "dismissed")

      get roles_path(answer: "not_found")

      expect(response.body).to include("Data Engineer")
      expect(response.body).not_to include("RevOps Engineer", "Old Role")
      expect(response.body).to match(/All <span class="count">2</)
      expect(response.body).to match(/No longer listed <span class="count">1</)
    end

    it "ignores an answer it does not know" do
      create(:posting, :verified_live, company: company, role_title: "RevOps Engineer")

      get roles_path(answer: "maybe")

      expect(response.body).to include("RevOps Engineer")
    end

    it "shows the dismissed tab, and an empty suggested one with what it is for" do
      create(:posting, company: company, role_title: "Office Manager", tracking: "dismissed")

      get roles_path(tab: "dismissed")
      expect(response.body).to include("Office Manager")

      get roles_path(tab: "suggested")
      expect(response.body).to include("No suggestions yet", "Find suggestions")
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

  describe "the watch list" do
    let(:role) { create(:posting, :verified_live, company: company, role_title: "RevOps Engineer") }

    it "dismisses a role with a note, audited as the operator, and goes back where it was" do
      patch dismiss_role_path(role), params: { note: "Needs relocation." }, headers: { "Referer" => roles_path(answer: "verified_live") }

      expect(response).to redirect_to(roles_path(answer: "verified_live"))
      expect(response).to have_http_status(:see_other)
      expect(role.reload.tracking).to eq("dismissed")
      expect(role.audit_events.sole).to have_attributes(actor: "human:operator",
                                                        reasoning: "Dismissed by hand: never checked or suggested again. Needs relocation.")
      follow_redirect!
      expect(response.body).to include("RevOps Engineer at Acme: dismissed.")
    end

    it "tracks a dismissed role again" do
      role.update!(tracking: "dismissed")

      patch track_role_path(role), params: { note: "Changed my mind." }

      expect(response).to redirect_to(role_path(role))
      expect(role.reload.tracking).to eq("tracked")
    end

    it "writes nothing without a note, and says why" do
      patch dismiss_role_path(role), params: { note: " " }

      expect(role.reload.tracking).to eq("tracked")
      expect(role.audit_events).to be_empty
      follow_redirect!
      expect(response.body).to include("say why: the note becomes the audit reasoning")
    end

    it "offers the button that fits: dismiss for a tracked role, track for a dismissed one" do
      get role_path(role)
      expect(response.body).to include(dismiss_role_path(role))
      expect(response.body).not_to include(track_role_path(role))

      role.update!(tracking: "dismissed")
      get role_path(role)
      expect(response.body).to include(track_role_path(role))
    end
  end
end
