require "rails_helper"

# Finding companies on the pages (4b step 3): the company preferences on the Profile page; the Companies page's
# Suggested tab (track or decline proposals, one or several), its Fit column, fit filters and sort, and its filters on
# a review's facts; a company's page with its proposal and its company review.
RSpec.describe "Finding companies", type: :request do
  let!(:profile) do
    SearchProfile.create!(titles: [ "Solutions Engineer" ], places: [ "Brazil" ], company_wants: "Products for revenue teams.",
                          company_models: %w[b2b], company_industries: [ "Fintech" ])
  end

  describe "the Profile page's company preferences" do
    it "shows them in their own form, with the version a review is read against and how many are due" do
      create(:company, :resolved, name: "Acme")

      get profile_path

      expect(response.body).to include("What you want of a company", "Products for revenue teams.", "Save company preferences",
                                       profile.company_preferences_version, "1 company tracked or proposed has no review")
      assert_select "input[type=checkbox][name='company_preferences[company_models][]'][value=b2b][checked]"
      assert_select "input[type=checkbox][name='company_preferences[company_stages][]'][checked]", count: 0
      assert_select "textarea[name='company_preferences[company_industries]']", text: /\AFintech\s*\z/
    end

    it "saves them as the operator, their own words by a hash alone, without touching the rest of the profile" do
      patch company_preferences_profile_path,
            params: { company_preferences: { company_wants: "Tools for support teams.", company_avoids: "Tracking people for ads.",
                                             company_stages: [ "", "series_a", "series_b" ], company_sizes: [ "", "51-200" ],
                                             company_models: [ "" ], company_industries: "Fintech\nDeveloper tools, Support",
                                             company_excluded: "Gambling" } }

      expect(response).to redirect_to(profile_path(anchor: "company"))
      expect(flash[:notice]).to eq("Company preferences saved. 0 companies tracked or proposed are due a review against them.")
      expect(profile.reload).to have_attributes(company_wants: "Tools for support teams.", company_stages: %w[series_a series_b],
                                                company_sizes: %w[51-200], company_models: [], company_excluded: %w[Gambling],
                                                company_industries: [ "Fintech", "Developer tools", "Support" ], titles: [ "Solutions Engineer" ])
      event = AuditEvent.where(target: profile).order(:occurred_at).last
      expect(event).to have_attributes(actor: "human:operator", reasoning: "Company preferences saved by hand.")
      expect(event.changes_made.to_json).not_to include("support teams", "Tracking people", "Gambling")

      patch company_preferences_profile_path, params: { company_preferences: { company_wants: "Tools for support teams." } }
      expect(flash[:notice]).to eq("Nothing to save: they are as they were.")

      patch company_preferences_profile_path, params: { company_preferences: { company_stages: [ "unicorn" ] } }
      expect(flash[:alert]).to start_with("Not saved: company stages can only be")
    end

    it "asks for the profile first" do
      profile.destroy!

      get profile_path
      expect(response.body).to include("Save the profile above first: the company preferences are kept with it.")
      patch company_preferences_profile_path, params: { company_preferences: { company_wants: "Anything." } }
      expect(flash[:alert]).to eq("Save the profile first: the company preferences are kept with it.")
    end
  end

  describe "the Suggested tab" do
    let!(:contoso) do
      create(:company, :proposed, name: "Contoso", domain: "contoso.example").tap do |company|
        company.update!(proposal: company.proposal.merge("query" => "solutions engineer brazil",
                                                         "seen" => { "board" => "https://jobs.ashbyhq.com/contoso", "roles" => 40, "fitting" => 3,
                                                                     "owner" => "confirmed", "read_at" => 1.hour.ago.iso8601 }))
      end
    end
    let!(:litware) do
      create(:company, :proposed, name: "Litware", domain: "litware.example").tap { |company| company.update!(proposal: company.proposal.except("link")) }
    end

    it "lists the proposals with where each was found, what its board listed, its fit and why, to track or decline" do
      create(:company, :resolved, name: "Acme")
      create(:company_review, company: contoso, score: 81)

      get companies_path(tab: "suggested")

      expect(response.body).to include("Suggested <span class=\"count\">2</span>", "Tracked <span class=\"count\">1</span>",
                                       "A job-board search (solutions engineer brazil)", "40 roles, 3 holding one of your titles",
                                       "the board names the company", "No known board among its links", "Sells to revenue teams in Brazil.",
                                       ">81<", "Track selected", "Archive selected", "Why track them, or decline them?")
      expect(response.body).not_to include("Acme<", "No careers page yet") # nothing is watched here: no needs-a-look filters
    end

    it "tracks several at once under one note, each board read once tracked, free; none when nothing is a proposal" do
      allow(DatabaseBackup).to receive(:daily)

      expect { patch track_many_companies_path, params: { ids: [ contoso.id, litware.id ], note: "Both fit." } }
        .to have_enqueued_job(CheckNowJob).exactly(:once)

      expect(flash[:notice]).to eq("2 companies tracked. 1 of their boards is being read now, free. " \
                                   "Check now finds the careers page of the other one.")
      expect([ contoso.reload.tracking, litware.reload.tracking ]).to eq(%w[tracked tracked])
      expect(CheckRun.sole).to have_attributes(company: contoso, kind: "company", request: { "read" => "board" }, ceiling_usd: 0)
      expect(AuditEvent.where(target: litware).order(:occurred_at).last.reasoning)
        .to eq("Tracked by hand: proposed by the operator's own Claude client. Both fit.")
      expect(DatabaseBackup).to have_received(:daily)

      patch track_many_companies_path, params: { ids: [ contoso.id ], note: "Again." }
      expect(flash[:alert]).to eq("Select the proposals to track first.")
    end

    it "declines several at once: archived, never proposed again" do
      allow(DatabaseBackup).to receive(:daily)

      patch dismiss_many_companies_path, params: { ids: [ contoso.id, litware.id ], note: "Not for me." }

      expect(flash[:notice]).to eq("2 proposals declined: archived, and never proposed again.")
      expect([ contoso.reload.tracking, litware.reload.tracking ]).to eq(%w[dismissed dismissed])
    end
  end

  describe "the Fit column, its filters and its sort, and the review's facts" do
    let!(:fabrikam) { create(:company, :resolved, name: "Fabrikam") }
    let!(:northwind) { create(:company, :resolved, name: "Northwind") }
    let!(:tailspin) { create(:company, :resolved, name: "Tailspin") }
    let!(:woodgrove) { create(:company, :resolved, name: "Woodgrove") }

    before do
      later { create(:company_review, company: fabrikam, score: 40) }
      later { create(:company_review, company: fabrikam, score: 88, stage: "series_b", industries: [ "Fintech" ], regions: [ "Latin America" ]) }
      later { create(:company_review, company: northwind, score: 64, stage: "seed", size: "11-50", industries: [ "fintech", "Retail" ]) }
      later { create(:company_review, company: tailspin, score: 75, preferences_digest: "sha256:before", business_model: "b2c") }
    end

    it "shows each company's newest score, stale ones marked, and narrows and sorts by it" do
      get companies_path

      expect(response.body).to include(">88<", ">64<", ">75<", "stale", "85 and up <span class=\"count\">1</span>",
                                       "70 and up <span class=\"count\">2</span>", "50 and up <span class=\"count\">3</span>",
                                       "Not reviewed <span class=\"count\">1</span>", "Stale <span class=\"count\">1</span>")
      expect(response.body).not_to include(">40<") # the newest is shown, the one before on its page

      get companies_path(fit: "70")
      expect(response.body).to include("Fabrikam", "Tailspin").and(not_include("Northwind", "Woodgrove"))
      get companies_path(fit: "none")
      expect(response.body).to include("Woodgrove").and(not_include("Fabrikam", "Tailspin"))
      get companies_path(fit: "stale")
      expect(response.body).to include("Tailspin").and(not_include("Fabrikam", "Woodgrove"))

      get companies_path(sort: "fit")
      expect(response.body.index("Fabrikam")).to be < response.body.index("Tailspin")
      expect(response.body.index("Tailspin")).to be < response.body.index("Northwind")
      expect(response.body.index("Northwind")).to be < response.body.index("Woodgrove")
    end

    it "narrows by the facts the newest reviews found, an industry whatever its case, keeping the tab and the fit" do
      get companies_path

      assert_select "select[name=stage] option[value=series_b]", text: "Series B"
      assert_select "select[name=stage] option[value=pre_seed]", count: 0 # only what reviews found
      assert_select "select[name=industry] option", text: "Fintech", count: 1
      assert_select "select[name=model] option[value=b2c]", text: "B2C"

      get companies_path(industry: "FINTECH")
      expect(response.body).to include("Fabrikam", "Northwind").and(not_include("Tailspin", "Woodgrove"))
      expect(response.body).to include("Tracked <span class=\"count\">2</span>")
      get companies_path(industry: "fintech", fit: "85")
      expect(response.body).to include("Fabrikam").and(not_include("Northwind"))
      get companies_path(stage: "seed", size: "11-50")
      expect(response.body).to include("Northwind").and(not_include("Fabrikam<"))
      get companies_path(region: "latin america", tab: "all")
      expect(response.body).to include("Fabrikam").and(not_include("Northwind", "Tailspin"))
      get companies_path(stage: "public")
      expect(response.body).to include("No company here with the filters chosen.")
    end
  end

  # 4b step 5: each role's company fit beside its own fit, never weighed into it.
  describe "company fit beside role fit" do
    let!(:fabrikam) { create(:company, :resolved, name: "Fabrikam") }
    let!(:northwind) { create(:company, :resolved, name: "Northwind") }
    let!(:analyst) { create(:posting, company: fabrikam, role_title: "Pipeline Analyst", tracking: "tracked") }
    let!(:architect) { create(:posting, company: northwind, role_title: "Revenue Architect", tracking: "tracked") }

    before do
      create(:company_review, company: northwind, score: 88)
      create(:company_review, company: fabrikam, score: 52, preferences_digest: "sha256:before")
    end

    it "shows each role's company fit on the Roles page, stale marked, and sorts by it or by the role's fit" do
      get roles_path

      expect(response.body).to include("Company fit", ">88<", ">52<", " stale", company_path(northwind, anchor: "review"))
      expect(response.body.index("Pipeline Analyst")).to be < response.body.index("Revenue Architect") # company order

      get roles_path(sort: "company_fit")
      expect(response.body).to include("Company fit ↓")
      expect(response.body.index("Revenue Architect")).to be < response.body.index("Pipeline Analyst")
      get roles_path(sort: "fit")
      expect(response.body).to include("Fit ↓").and(not_include("Company fit ↓"))
    end

    it "shows a role's company fit on its page, linked to the review, or that its company isn't reviewed" do
      get role_path(analyst)
      expect(response.body).to include("Company fit", ">52<", "Fabrikam&#39;s review", company_path(fabrikam, anchor: "review"),
                                       "a separate score, never weighed into this role's fit")

      bare = create(:posting, company: create(:company, :resolved, name: "Woodgrove"), role_title: "Deal Desk Analyst")
      get role_path(bare)
      expect(response.body).to include("not reviewed", "your own Claude client reviews a company only when you ask")
    end
  end

  describe "a company's page" do
    let!(:company) { create(:company, :resolved, name: "Fabrikam", domain: "fabrikam.example") }

    it "shows its newest review in full, the scores before it, and says when it is stale or thin" do
      later { create(:company_review, company: company, score: 58) }
      later do
        create(:company_review, company: company, score: 49, stage: "series_b", size: "201-500", industries: [ "Fintech" ],
                                regions: [ "Latin America" ], reported_model: "claude-opus-5-5",
                                facts: [ { "about" => "last_funding", "said" => "A Series B in 2026.", "sources" => [ "https://news.example/fabrikam" ] } ],
                                points: [ { "about" => "avoids", "preference" => "Tracking people for ads.", "verdict" => "miss",
                                            "evidence" => "Its ad product profiles visitors.", "sources" => [ "https://fabrikam.example/ads" ] },
                                          { "about" => "places", "preference" => "Brazil", "verdict" => "unknown" },
                                          { "about" => "size", "preference" => "51-200", "verdict" => "unknown" } ],
                                concerns: [ "An ad product beside the main one." ], questions: [ "Is the ad product growing?" ])
      end

      get company_path(company)

      expect(response.body).to include("Company review", ">49<", "Series B · 201-500 people · B2B · Fintech · hires in Latin America",
                                       "What you avoid:", "Tracking people for ads.", ">missed<", "Its ad product profiles visitors.",
                                       "fabrikam.example", "Where you can work:", ">unknown<", "Last funding:", "A Series B in 2026.",
                                       "news.example", "An ad product beside the main one.", "Is the ad product growing?",
                                       "1 source checked", "your Claude client, through MCP", "model reported: claude-opus-5-5",
                                       "It knows less than it doesn't", "Before: 58 on")
      expect(response.body).not_to include("changed since it was reviewed")

      profile.update!(company_wants: "Something else.")
      get company_path(company)
      expect(response.body).to include("Your company preferences or places changed since it was reviewed")
    end

    it "says why it has no review: no preferences yet, or none asked for" do
      get company_path(company)
      expect(response.body).to include("Not reviewed yet. Your own Claude client reviews a company only when you ask it to")

      profile.update!(company_wants: nil, company_models: [], company_industries: [])
      get company_path(company)
      expect(response.body).to include("Not reviewed. A review weighs a company against what you want of one")
    end

    it "shows a proposal's why, where it was found and what its board listed; kept once it is tracked" do
      proposal = create(:company, :proposed, name: "Contoso", domain: "contoso.example")
      proposal.update!(proposal: proposal.proposal.merge("links" => [ "https://news.example/contoso-raises" ], "reported_model" => "claude-opus-5-5",
                                                         "seen" => { "read" => "nothing read", "why" => "No known board at that link." }))

      get company_path(proposal)
      expect(response.body).to include(">Proposed<", "Sells to revenue teams in Brazil.", "A job-board search",
                                       "Nothing read: No known board at that link.", "jobs.ashbyhq.com/contoso", "news.example/contoso-raises",
                                       "model reported: claude-opus-5-5", "Not reviewed yet.")
      expect(response.body.index(">Proposed<")).to be < response.body.index("Check its careers page now")

      Verifier::Tracking.track_company!(proposal, note: "It fits.")
      get company_path(proposal)
      expect(response.body).to include("How it was proposed", "Sells to revenue teams in Brazil.")
      expect(response.body.index("How it was proposed")).to be > response.body.index("Check its careers page now")
    end
  end
end
