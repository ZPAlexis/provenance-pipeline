require "rails_helper"

RSpec.describe "Suggestions", type: :request do
  def refreshed(created: 0, withdrawn: 0, problems: [], run_id: "20261008T120000Z-suggest")
    Verifier::Suggestions::Refresh.new(created: created, updated: 0, withdrawn: withdrawn, problems: problems, run_id: run_id)
  end

  describe "POST /suggestions" do
    it "brings the suggestions up to date and says what changed" do
      allow(Verifier::Suggestions).to receive(:refresh!).and_return(refreshed(created: 3, withdrawn: 1))

      post suggestions_path

      expect(response).to redirect_to(roles_path(tab: "suggested"))
      expect(flash[:notice]).to eq("Suggestions: 3 new, 1 withdrawn.")
    end

    it "asks for a profile when none is saved" do
      allow(Verifier::Suggestions).to receive(:refresh!).and_return(refreshed(problems: [ "No search profile is saved yet." ], run_id: nil))

      post suggestions_path

      expect(response).to redirect_to(profile_path)
      expect(flash[:alert]).to eq("No search profile is saved yet. Save one first.")
    end

    it "says so when the worker fails" do
      allow(Verifier::Suggestions).to receive(:refresh!).and_raise(Verifier::Worker::Error, "the verification worker exited with status 1")

      post suggestions_path

      expect(flash[:alert]).to eq("Suggestions could not be found: the verification worker exited with status 1")
    end
  end

  describe "PATCH /profile" do
    it "brings the suggestions up to date with the profile just saved" do
      allow(Verifier::Suggestions).to receive(:refresh!).and_return(refreshed(created: 2))

      patch profile_path, params: { search_profile: { titles_text: "Solutions Engineer", work_modes: [ "" ], levels: [ "" ] } }

      expect(Verifier::Suggestions).to have_received(:refresh!).with(profile: SearchProfile.current)
      expect(flash[:notice]).to eq("Profile saved. Suggestions: 2 new.")
    end
  end

  describe "the Suggested tab" do
    let(:company) { create(:company, :resolved, name: "Acme") }

    it "shows why each role was suggested, and the button to find more" do
      create(:posting, :verified_live, company: company, role_title: "Solutions Engineer", tracking: "suggested",
                                       fit: { "reasoning" => "Its title holds every word of \"Solutions Engineer\".",
                                              "notes" => [ "place_not_stated" ] })

      get roles_path(tab: "suggested")

      expect(response.body).to include("Why suggested", "Its title holds every word of", "No place stated", "Find suggestions")
    end

    it "explains a suggestion withdrawn since its page was opened" do
      role = create(:posting, company: company, role_title: "Solutions Engineer", tracking: "suggested")
      AuditEvent.record_destroy!(role, actor: "agent:suggester", reasoning: "Withdrawn: it is no longer listed.")
      role.destroy!

      get role_path(role.id)

      expect(response).to redirect_to(roles_path(tab: "suggested"))
      expect(flash[:alert]).to eq("Solutions Engineer is no longer suggested. Withdrawn: it is no longer listed.")

      get role_path(SecureRandom.uuid) # never a role, nor withdrawn: missing, as any record is
      expect(flash[:alert]).to eq("The record you were looking for could not be found.")
    end
  end
end
