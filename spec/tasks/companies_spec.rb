require "rails_helper"

# The companies: commands (4b): the company preferences shown and saved, and the companies' reviews.
RSpec.describe "companies: commands" do
  let!(:profile) { SearchProfile.create!(titles: [ "Solutions Engineer" ], places: [ "Brazil" ]) }
  let!(:company) { create(:company, :resolved, name: "Fabrikam", domain: "fabrikam.example") }

  it "shows the company preferences, and saves those given, audited as you" do
    expect(run_task("companies:preferences").out).to include("No company preferences yet")

    saved = run_task("companies:preferences", WANTS: "Products for revenue teams.", STAGES: "series_a,series_b", MODELS: "b2b")
    expect(saved.out).to include("Backed up to", "Company preferences saved.", "Wants: Products for revenue teams.",
                                 "Stages: Series A, Series B", "Business models: B2B", "Version #{profile.reload.company_preferences_version}")
    expect(AuditEvent.where(target: profile).sole.actor).to eq("human:operator")
    expect(run_task("companies:preferences", STAGES: "unicorn").aborted).to start_with("Company stages can only be")
  end

  it "lists the companies by their newest review, a stale one marked, those due, and one review in full" do
    CompanyPreferences.save!(profile, company_wants: "Products for revenue teams.")
    contoso = create(:company, :proposed, name: "Contoso", domain: "contoso.example")
    as_agent("agent:assistant", scopes: %w[company_reviews:write]) do
      CompanyReviews.save!(company, score: 81, why: "It sells to revenue teams.", preferences_version: profile.reload.company_preferences_version,
                                    stage: "series_b", points: [ { about: "wants", preference: "Products for revenue teams.", verdict: "match",
                                                                   evidence: "Its product page." } ],
                                    sources: [ "https://fabrikam.example/product" ])
    end

    expect(run_task("companies:reviews").out).to include("1 companies, best first:", " 81  Fabrikam  81, 1 met, 0 missed, 0 unknown")
    expect(run_task("companies:reviews", DUE: "1").out).to include("1 due a review:", "- Contoso (contoso.example, suggested): #{contoso.id}")
    shown = run_task("companies:review", "fabrikam").out
    expect(shown).to include("Fabrikam: 81, by your Claude client, through MCP", "Why: It sells to revenue teams.",
                             "match: Products for revenue teams. (Its product page.)", "Facts: Stage Series B",
                             "Sources: https://fabrikam.example/product")

    later { CompanyPreferences.save!(profile, company_avoids: "Surveillance tools.") }
    expect(run_task("companies:reviews").out).to include("Fabrikam (stale: the preferences changed)")
    expect(run_task("companies:review", "Contoso").aborted).to eq("Contoso has no review yet.")
  end
end
