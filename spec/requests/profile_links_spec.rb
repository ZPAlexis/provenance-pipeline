require "rails_helper"

# The operator's own links on the Profile page (4d step 3): saved as given (never LinkedIn), then read in the
# background, free; what each read found shown under them, its pages folded.
RSpec.describe "Your links, on the Profile page", type: :request do
  let!(:profile) { SearchProfile.create!(titles: [ "Solutions Engineer" ]) }

  it "saves the links as typed and reads them in the background, free" do
    expect { patch links_profile_path, params: { links: [ { label: "Website", url: "jordan.example/en" }, { label: "", url: "" } ] } }
      .to have_enqueued_job(CheckNowJob)

    expect(response).to redirect_to(profile_path(anchor: "links"))
    expect(profile.profile_links.sole).to have_attributes(label: "Website", url: "https://jordan.example/en")
    expect(CheckRun.sole).to have_attributes(kind: "links", ceiling_usd: 0, company: nil)
  end

  it "refuses LinkedIn, keeping what was typed on the page" do
    patch links_profile_path, params: { links: [ { label: "LinkedIn", url: "https://www.linkedin.com/in/jsample" } ] }

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.body).to include("Not saved: https://www.linkedin.com/in/jsample: LinkedIn isn&#39;t read",
                                     "value=\"https://www.linkedin.com/in/jsample\"")
    expect(profile.profile_links).to be_empty
  end

  it "shows what each read found, its pages folded, and reads them again when asked" do
    link = ProfileLinks.keep!(profile, [ { label: "Website", url: "https://jordan.example" } ]).sole
    at = 1.day.ago.change(usec: 0)
    link.link_pages.create!(url: "https://jordan.example", title: "Home", text: "Jordan Sample, solutions engineer.",
                            content_hash: Resume.digest("Jordan Sample"), read_via: "render", run_id: "r1", first_read_at: at, last_read_at: at)
    link.update!(read_at: at, read_outcome: "ok", read_skipped: 1)

    get profile_path
    expect(response.body).not_to include("&lt;time") # when it was read, as a time, never its markup as text
    expect(response.body).to include("Your links", "<strong>Website</strong>", "jordan.example", "1 page, 1 left unread, read <time",
                                     "1 page, 4 words", ">Home</a>", "LinkedIn isn't read",
                                     "click \"Read them again\" before weighing a role or reviewing your resume for one again")

    expect { post read_links_profile_path }.to have_enqueued_job(CheckNowJob)
    expect(CheckRun.sole.kind).to eq("links")
  end
end
