require "rails_helper"

RSpec.describe "Profile", type: :request do
  let(:fields) do
    { titles_text: "Solutions Engineer\nRevOps", excluded_words_text: "Intern", places_text: "Brazil\nLATAM",
      work_modes: [ "", "remote", "hybrid" ], levels: [ "" ] }
  end

  describe "GET /profile" do
    it "starts a profile with every work mode, before one is saved" do
      get profile_path

      expect(response).to have_http_status(:success)
      expect(response.body).to include("Search profile", "Preview", 'id="profile-preview"')
      SearchProfile::WORK_MODES.each { |mode| assert_select "input[type=checkbox][value=#{mode}][checked]" }
      assert_select "input[type=checkbox][name='search_profile[levels][]'][checked]", count: 0
    end
  end

  describe "PATCH /profile" do
    it "saves the profile, audited as the operator" do
      expect { patch profile_path, params: { search_profile: fields } }.to change(SearchProfile, :count).by(1)

      expect(response).to redirect_to(profile_path)
      profile = SearchProfile.current
      expect(profile).to have_attributes(titles: [ "Solutions Engineer", "RevOps" ], excluded_words: [ "Intern" ],
                                         places: %w[Brazil LATAM], work_modes: %w[remote hybrid], levels: [])
      event = AuditEvent.find_by!(target: profile)
      expect(event).to have_attributes(actor: "human:operator", action: "create", reasoning: "Saved on the Profile page.")

      patch profile_path, params: { search_profile: fields.merge(places_text: "Brazil") }
      expect(SearchProfile.count).to eq(1)
      # Audit ids are random UUIDs: the update is asked for by its action, never by order.
      update = AuditEvent.find_by!(target: profile, action: "update")
      expect(update.changes_made).to eq("places" => [ %w[Brazil LATAM], [ "Brazil" ] ])
    end

    it "says what is wrong, and saves nothing" do
      patch profile_path, params: { search_profile: fields.merge(titles_text: "  ") }

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include("Titles need at least one")
      expect(SearchProfile.count).to eq(0)
    end
  end

  describe "PATCH /profile/preview" do
    it "weighs the profile on the page, saved or not, and writes nothing" do
      company = create(:company, :resolved, name: "Acme")
      fit = Verifier::Suggestions::Fit.new(
        company: company, listing: { "title" => "Solutions Engineer", "location" => "Remote", "url" => "javascript:alert(1)" },
        title: "Solutions Engineer", level: nil, place: nil, work_mode: "unknown", suggested: true, ruled_out: nil, on_record: nil,
        notes: [ "place_not_stated" ], reasoning: "Its title holds every word of \"Solutions Engineer\"."
      )
      preview = Verifier::Suggestions::Preview.new(companies: 1, unread: 0, weighed: 12, read_between: [ 1.day.ago, 1.day.ago ],
                                                   fits: [ fit ], problems: [])
      allow(Verifier::Suggestions).to receive(:preview).and_return(preview)

      expect { patch preview_profile_path, params: { search_profile: fields }, headers: { "Turbo-Frame" => "profile-preview" } }
        .not_to change { [ SearchProfile.count, AuditEvent.count ] }

      expect(Verifier::Suggestions).to have_received(:preview).with(have_attributes(titles: [ "Solutions Engineer", "RevOps" ]))
      expect(response.body).to include("Would suggest 1 new role", "Weighed 12 roles", "Acme", "No place stated: 1")
      expect(response.body).not_to include('href="javascript:') # a page's address is a link only when it is a web address
    end

    it "says what is wrong, and runs nothing" do
      allow(Verifier::Suggestions).to receive(:preview)

      patch preview_profile_path, params: { search_profile: fields.merge(titles_text: "") }

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include("Titles need at least one")
      expect(Verifier::Suggestions).not_to have_received(:preview)
    end
  end
end
