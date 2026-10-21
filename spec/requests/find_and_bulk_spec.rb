require "rails_helper"

RSpec.describe "Finding roles and companies, and dismissing roles at once", type: :request do
  let!(:acme) { create(:company, :resolved, name: "Acme", domain: "acme.example") }
  let!(:globex) { create(:company, :resolved, name: "Globex", domain: "globex.example") }
  let!(:sao_paulo) { create(:posting, company: acme, role_title: "Sales Engineer", location: "São Paulo, Brazil") }
  let!(:remote) { create(:posting, company: acme, role_title: "Solutions Engineer", location: "Remote - LATAM") }
  let!(:berlin) { create(:posting, company: globex, role_title: "Sales Engineer", location: "Berlin, Germany") }

  describe "Find" do
    # The cell, not the Add a role form's placeholder, which names São Paulo too.
    def cell(place) = "<td class=\"muted\">#{place}</td>"

    it "narrows the roles to those holding every word typed, case and accents set aside, the tabs' counts with them" do
      get roles_path(q: "sao PAULO")

      expect(response.body).to include(cell("São Paulo, Brazil")).and(not_include(cell("Berlin, Germany"), cell("Remote - LATAM")))
      expect(response.body).to include("Tracked <span class=\"count\">1</span>", "value=\"sao PAULO\"", "Clear")

      get roles_path(q: "sales engineer germany")
      expect(response.body).to include(cell("Berlin, Germany")).and(not_include(cell("São Paulo, Brazil")))

      get roles_path(q: "globex")
      expect(response.body).to include(cell("Berlin, Germany")).and(not_include(cell("São Paulo, Brazil")))

      get roles_path(q: "Lisbon")
      expect(response.body).to include("No tracked role matches “Lisbon”.")
    end

    it "keeps the tab and the answer it narrows within" do
      get roles_path(tab: "suggested", answer: "pending", q: "brazil")

      expect(response.body).to include('name="tab" value="suggested"', 'name="answer" value="pending"')
      expect(response.body).to include("/roles?answer=pending&amp;q=brazil&amp;tab=suggested")
    end

    it "finds companies by name, domain, or a place one of their roles is in" do
      get companies_path(q: "brazil")
      expect(response.body).to include("Acme").and(not_include("Globex"))

      get companies_path(q: "globex.example")
      expect(response.body).to include("Globex").and(not_include(">Acme<"))

      get companies_path(q: "Lisbon")
      expect(response.body).to include("No company here matches “Lisbon”.")
    end
  end

  describe "dismissing roles at once" do
    before { allow(DatabaseBackup).to receive(:daily) }

    it "offers it on the tracked and suggested tabs, never the dismissed one" do
      get roles_path
      expect(response.body).to include("Dismiss selected", 'form="bulk-dismiss"')

      sao_paulo.update!(tracking: "dismissed")
      get roles_path(tab: "dismissed")
      expect(response.body).not_to include("Dismiss selected")
    end

    it "dismisses every role picked under one note, each audited on its own, backed up first" do
      patch dismiss_many_roles_path, params: { ids: [ sao_paulo.id, berlin.id ], note: "Not my area." }

      expect(flash[:notice]).to eq("2 roles dismissed: never checked or suggested again.")
      expect([ sao_paulo, berlin, remote ].map { |role| role.reload.tracking }).to eq(%w[dismissed dismissed tracked])
      expect(AuditEvent.where(action: "update", target_type: "Posting").pluck(:reasoning).uniq)
        .to eq([ "Dismissed by hand: never checked or suggested again. Not my area." ])
      expect(DatabaseBackup).to have_received(:daily)
    end

    it "dismisses none without a note, or with nothing picked" do
      patch dismiss_many_roles_path, params: { ids: [ sao_paulo.id ], note: " " }
      expect(flash[:alert]).to eq("None dismissed: say why: the note becomes the audit reasoning.")

      patch dismiss_many_roles_path, params: { note: "Why." }
      expect(flash[:alert]).to eq("Select the roles to dismiss first.")
      expect(Posting.where(tracking: "dismissed")).to be_empty
    end
  end

  it "opens one decision at a time on a role, with its own Cancel" do
    suggested = create(:posting, company: acme, role_title: "GTM Engineer", tracking: "suggested")

    get role_path(suggested)

    expect(response.body).to include('data-controller="fold"', 'data-action="fold#close"')
    expect(response.body.scan(/<summary class="btn small">(Track|Dismiss)<\/summary>/).flatten).to eq(%w[Track Dismiss])
  end
end
