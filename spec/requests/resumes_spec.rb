require "rails_helper"

RSpec.describe "The resume", type: :request do
  let!(:profile) { SearchProfile.create!(titles: [ "Sales Engineer" ]) }

  def resume_events = AuditEvent.where(target_type: "Resume").order(:occurred_at)

  it "is kept with the profile, version by version, its record naming its size and hash, never its text" do
    patch resume_profile_path, params: { resume_text: "Alex Example\nSales engineer, eight years." }
    expect(flash[:notice]).to eq("Resume kept: 6 words.")

    patch resume_profile_path, params: { resume_text: "Alex Example\nSales engineer, eight years." }
    expect(flash[:notice]).to eq("The same resume as now: nothing changed.")

    patch resume_profile_path, params: { resume_text: "Alex Example\nSales engineer, nine years, Portuguese." }

    expect(profile.resumes.newest_first.map(&:words)).to eq([ 7, 6 ])
    expect(resume_events.map(&:reasoning)).to eq([ "Resume kept on the Profile page: 6 words.",
                                                   "Resume replaced on the Profile page: 7 words." ])
    expect(resume_events.map { |event| event.changes_made.to_json }.join).not_to include("eight", "nine", "Alex")

    get profile_path
    expect(response.body).to include("7 words", "1 earlier version", "Portuguese")
  end

  it "is removed whole, with every version, the record keeping only sizes and hashes" do
    patch resume_profile_path, params: { resume_text: "First." }
    patch resume_profile_path, params: { resume_text: "Second." }

    delete resume_profile_path

    expect(flash[:notice]).to eq("Resume removed, with all 2 of its versions.")
    expect(Resume.count).to eq(0)
    expect(resume_events.where(action: "destroy").count).to eq(2)
    expect(resume_events.map { |event| event.changes_made.to_json }.join).not_to include("First", "Second")
  end

  it "is never written by an agent" do
    expect { as_agent("agent:verifier") { profile.resumes.create!(text: "x", content_hash: Resume.digest("x")) } }
      .to raise_error(Authority::Denied, /may not create a resume/)
  end

  it "waits for a saved profile, and refuses an empty one" do
    profile.destroy!
    patch resume_profile_path, params: { resume_text: "Text." }
    expect(flash[:alert]).to start_with("Save the profile first")

    SearchProfile.create!(titles: [ "Sales Engineer" ])
    patch resume_profile_path, params: { resume_text: "   " }
    expect(flash[:alert]).to eq("Not kept: paste the resume's text first.")
  end
end
