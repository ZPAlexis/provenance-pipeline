require "rails_helper"

# A company review (4b): how well a company fits the operator's company preferences, as their own client researched
# it, saved under company_reviews:write against the preferences version it read; kept, the newest shown, stale when the
# preferences or the places change; audited by its score, counts and digests, never its text.
RSpec.describe CompanyReviews do
  let!(:profile) do
    SearchProfile.create!(titles: [ "Solutions Engineer" ], places: [ "Brazil" ], company_wants: "Products for revenue teams.",
                          company_avoids: "Surveillance tools.", company_models: %w[b2b], company_excluded: %w[gambling])
  end
  let!(:company) { create(:company, :resolved, name: "Fabrikam", domain: "fabrikam.example") }

  def review(**given)
    { score: 78, why: "It sells to revenue teams and hires in Brazil; its funding is unknown.",
      preferences_version: profile.company_preferences_version, stage: "series_b", size: "201-500", business_model: "b2b",
      industries: [ "Fintech", "fintech", "Sales tools" ], regions: [ "Latin America", "United States" ],
      facts: [ { about: "sells", said: "A forecasting tool for sales teams.", sources: [ "https://fabrikam.example/product" ] },
               { about: "funding", said: " " } ],
      points: [ { about: "wants", preference: "Products for revenue teams.", verdict: "match", evidence: "Its product page.",
                  sources: [ "https://fabrikam.example/product" ] },
                { about: "avoids", preference: "Surveillance tools.", verdict: "match", evidence: "Nothing of the kind found." },
                { about: "places", preference: "Brazil", verdict: "match", evidence: "Hires in São Paulo." },
                { about: "stage", preference: "Series A or B", verdict: "unknown" } ],
      concerns: [ "A small team in Brazil." ], questions: [ "Is the role remote?" ], sources: [ "https://fabrikam.example/careers" ],
      reported_model: "claude-opus-5-5" }.merge(given)
  end

  def save(company = self.company, **given)
    as_agent("agent:assistant", scopes: %w[company_reviews:write]) { described_class.save!(company, **review(**given)) }
  end

  it "saves the client's review, its facts in the preferences' own values, audited by counts and digests alone" do
    saved, said = save

    expect(saved).to have_attributes(score: 78, stage: "series_b", size: "201-500", business_model: "b2b", industries: [ "Fintech", "Sales tools" ],
                                     regions: [ "Latin America", "United States" ], written_by: "agent:assistant", reported_model: "claude-opus-5-5",
                                     preferences_digest: profile.company_preferences_digest)
    expect(saved.facts).to eq([ { "about" => "sells", "said" => "A forecasting tool for sales teams.", "sources" => [ "https://fabrikam.example/product" ] } ])
    expect(saved.tally).to eq("match" => 3, "miss" => 0, "unknown" => 1)
    expect(said).to eq("78, 3 met, 0 missed, 1 unknown.")
    expect(saved).not_to be_stale
    event = AuditEvent.find_by!(target: saved)
    expect(event.changes_made).to include("score" => [ nil, 78 ], "points" => [ nil, { "match" => 3, "miss" => 0, "unknown" => 1 } ],
                                          "facts" => [ nil, 1 ], "sources" => [ nil, 2 ])
    expect(event.changes_made.to_json).not_to include("revenue", "Surveillance", "forecasting")
    expect(event.credential.reload).to have_attributes(scopes: %w[company_reviews:write], status: "revoked")
  end

  it "keeps every review, the newest shown, stale once the preferences or the places change; and says which are due" do
    proposal = create(:company, :proposed, name: "Contoso", domain: "contoso.example")
    create(:company, name: "Archived Co", domain: "archived.example", tracking: "dismissed")
    first, = later { save }
    newest, = later { save(score: 64) }

    expect(described_class.newest(company)).to eq(newest)
    expect(company.company_reviews.count).to eq(2)
    expect(described_class.due.map(&:name)).to eq([ "Contoso" ])
    expect(proposal).to be_suggested

    profile.update!(places: [ "Portugal" ])
    expect([ first.stale?, newest.stale? ]).to eq([ true, true ])
    expect(described_class.due.map(&:name)).to contain_exactly("Fabrikam", "Contoso")
  end

  it "refuses a review against preferences changed since, without preferences, of an archived company, or unsourced" do
    stale = review[:preferences_version]
    profile.update!(company_models: %w[b2c])

    expect { save(preferences_version: stale) }.to raise_error(ArgumentError, /the company preferences changed since you read them/)
    expect { save(company.tap { |each| each.update!(tracking: "dismissed") }) }.to raise_error(ArgumentError, "Fabrikam is archived: it isn't reviewed")
    company.update!(tracking: "tracked")
    expect { save(score: 101) }.to raise_error(ArgumentError, "a score is a whole number from 0 to 100")
    expect { save(sources: [], facts: [], points: [ { about: "wants", preference: "x", verdict: "unknown" } ]) }
      .to raise_error(ArgumentError, "name the sources checked: a review rests on them")
    expect { save(sources: [ "fabrikam.example" ]) }.to raise_error(ArgumentError, "fabrikam.example is not a web address: a source is a link")
    expect { save(points: [ { about: "vibes", preference: "x", verdict: "match" } ]) }.to raise_error(ActiveRecord::RecordInvalid, /must say what it weighs/)
    expect { save(points: [ { about: "wants", preference: "x", verdict: "maybe" } ]) }.to raise_error(ActiveRecord::RecordInvalid, /verdict can only be/)

    profile.update!(company_wants: nil, company_avoids: nil, company_models: [], company_excluded: [])
    expect { save }.to raise_error(ArgumentError, "the profile has no company preferences yet: the operator sets them first")
    expect(CompanyReview.count).to eq(0)
  end

  it "caps the score of a company that does what the operator avoids, and says when it knows less than it doesn't" do
    avoided = [ { about: "excluded", preference: "gambling", verdict: "miss", evidence: "It runs a betting app.", sources: [ "https://fabrikam.example/" ] } ]

    expect { save(points: avoided) }.to raise_error(ActiveRecord::RecordInvalid, /Score can be at most 49: it does something the operator avoids/)
    capped, = later { save(score: 30, points: avoided) }
    expect(capped.score).to eq(30)

    thin, said = later { save(points: [ { about: "wants", preference: "x", verdict: "match" }, { about: "stage", preference: "y", verdict: "unknown" },
                                        { about: "size", preference: "z", verdict: "unknown" } ]) }
    expect(thin).to be_thin
    expect(said).to eq("78, 1 met, 0 missed, 2 unknown, knowing less than it doesn't.")
  end

  it "is the client's write alone, under company_reviews:write, which never edits or deletes one" do
    expect { described_class.save!(company, **review) }.to raise_error(Authority::Denied)
    saved, = save

    as_agent("agent:assistant", scopes: %w[company_reviews:write]) do
      expect { saved.update!(score: 90) }.to raise_error(Authority::Denied)
      expect { saved.destroy! }.to raise_error(Authority::Denied)
      # Another writer is refused by the scope itself, before any validation could say so.
      other = company.company_reviews.new(**saved.attributes.except("id", "created_at", "updated_at"), written_by: "agent:fit_scorer")
      expect { other.save!(validate: false) }.to raise_error(Authority::Denied)
    end
  end
end
