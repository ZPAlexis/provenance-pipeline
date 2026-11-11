require "rails_helper"

# The operator's background beyond the resume (4c): three parts, each read only by what may use it, kept with the
# profile version by version as the resume is, its record naming each part's size and hash, never its text.
RSpec.describe "The background", type: :request do
  let!(:profile) { SearchProfile.create!(titles: [ "Sales Engineer" ]) }

  def background_events = AuditEvent.where(target_type: "Background").order(:occurred_at)

  def save(**parts) = patch(background_profile_path, params: { background: parts })

  it "shows its three parts on the Profile page, each with what reads it" do
    get profile_path

    expect(response.body).to include("Background information", "What I&#39;m looking for", "Role preferences", "Background not on the resume",
                                     "never as a claim of experience", "Read only by role fit, never by a draft",
                                     "from your background, not on the resume", "Save background")
  end

  it "is kept with the profile, version by version, its record naming each part's size and hash, never its text" do
    later { save(looking_for: "A long-term role building revenue systems.", role_preferences: "Titles: GTM Engineer.\r\nRemote first.") }
    expect(flash[:notice]).to eq("Background saved: 11 words (what you're looking for 6, role preferences 5, background not on the resume 0).")

    later { save(looking_for: "A long-term role building revenue systems.", role_preferences: "Titles: GTM Engineer.\nRemote first.") }
    expect(flash[:notice]).to eq("Nothing to save: it is the same as now.")

    later { save(looking_for: "A long-term role building revenue systems.", role_preferences: "Titles: GTM Engineer.\nRemote first.",
                 not_on_resume: "Portuguese, native. English, fluent.") }

    newest, first = profile.backgrounds.newest_first.to_a
    expect([ newest.words, first.words ]).to eq([ 15, 11 ])
    expect(newest.hash_of("looking_for")).to eq(first.hash_of("looking_for"))
    expect(newest.version).not_to eq(first.version)
    expect(background_events.map(&:reasoning)).to eq([
      "Background saved on the Profile page: 11 words (what you're looking for 6, role preferences 5, background not on the resume 0).",
      "Background changed on the Profile page: 15 words (what you're looking for 6, role preferences 5, background not on the resume 4)."
    ])
    # Only the part that changed is named on the second event: by its hash and words, never its text.
    expect(background_events.last.changes_made.keys).to contain_exactly("content_hash", "not_on_resume_hash", "not_on_resume_words")
    expect(background_events.map { |event| event.changes_made.to_json }.join).not_to include("revenue", "GTM", "Portuguese")

    get profile_path
    expect(response.body).to include("15 words", "version", newest.version, "1 earlier version", "Portuguese, native.", "Save changes",
                                     "Delete background")
  end

  it "refuses a part over its limit, or none at all, showing what was typed again" do
    save(not_on_resume: "word " * 2_100, looking_for: "Kept on the page.")

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.body).to include("Not saved: &quot;Background not on the resume&quot; is 10499 characters, over 10000", "Kept on the page.")
    save(looking_for: "  ")
    expect(response.body).to include("Not saved: write at least one part first.")
    expect(Background.count).to eq(0)
  end

  it "is removed whole, with every version, the record keeping only sizes and hashes" do
    save(looking_for: "First.")
    save(looking_for: "Second.")

    delete background_profile_path

    expect(flash[:notice]).to eq("Background deleted, with all 2 of its saved versions.")
    expect(Background.count).to eq(0)
    expect(background_events.where(action: "destroy").count).to eq(2)
    expect(background_events.map { |event| event.changes_made.to_json }.join).not_to include("First", "Second")
    delete background_profile_path
    expect(flash[:alert]).to eq("There is no background to remove.")
  end

  it "is never written by an agent, and is the operator's alone on the Agents page" do
    expect { as_agent("agent:assistant") { Background.of(profile, looking_for: "x").save! } }
      .to raise_error(Authority::Denied, /may not create a background/)
    expect(Authority::HUMAN_ONLY).to include(a_string_including("the resume, or the background information"))
  end

  it "waits for a saved profile" do
    profile.destroy!
    get profile_path
    expect(response.body).to include("Save the profile above first: the background is kept with it.")
    save(looking_for: "Text.")
    expect(flash[:alert]).to eq("Save the profile first: the background is kept with it.")
  end
end
