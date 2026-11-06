require "rails_helper"

# What the operator wants of a company (4b), on the search profile: saved by the operator or by their own client on
# their word, their own words audited by a hash alone, and one digest a company review is read against.
RSpec.describe CompanyPreferences do
  let!(:profile) { SearchProfile.create!(titles: [ "Solutions Engineer" ], places: [ "Brazil" ]) }

  let(:given) do
    { company_wants: "Products for revenue teams; a team that ships weekly.", company_avoids: "Companies that sell surveillance tools.",
      company_stages: "series_a, series_b", company_sizes: [ "51-200", "201-500" ], company_models: "b2b",
      company_industries: "Fintech\nDevtools", company_excluded: "gambling, defense" }
  end

  it "saves the company preferences, the operator's own words audited by a hash alone, the lists as they are" do
    described_class.save!(profile, given)

    expect(profile.reload).to have_attributes(company_wants: "Products for revenue teams; a team that ships weekly.",
                                              company_stages: %w[series_a series_b], company_sizes: %w[51-200 201-500],
                                              company_models: %w[b2b], company_industries: %w[Fintech Devtools],
                                              company_excluded: %w[gambling defense])
    event = AuditEvent.where(target: profile).sole
    expect(event).to have_attributes(actor: "human:operator", reasoning: "Company preferences saved by hand.")
    expect(event.changes_made["company_wants"]).to eq([ nil, Resume.digest("Products for revenue teams; a team that ships weekly.") ])
    expect(event.changes_made["company_excluded"]).to eq([ nil, Resume.digest("gambling\ndefense") ])
    expect(event.changes_made["company_stages"]).to eq([ [], %w[series_a series_b] ])
    expect(event.changes_made.to_json).not_to include("surveillance", "revenue teams", "gambling")
    expect(described_class.said(profile)).to include("Stages: Series A, Series B", "Sizes: 51-200, 201-500 people", "Business models: B2B")
  end

  it "changes nothing it isn't given, saves nothing unchanged, and refuses what isn't a company preference" do
    described_class.save!(profile, given)

    expect(described_class.save!(profile, company_models: "b2b")).to be_nil
    expect { described_class.save!(profile, titles: [ "Sales" ]) }.to raise_error(ArgumentError, "only the company preferences are saved here, not titles")
    expect { described_class.save!(profile, company_stages: "unicorn") }
      .to raise_error(ArgumentError, /company stages can only be pre_seed, seed/)
    expect { described_class.save!(SearchProfile.new, given) }.to raise_error(ArgumentError, /save the search profile first/)
    expect(AuditEvent.where(target: profile).count).to eq(1)
  end

  it "has one digest a review is read against: its company preferences and its places, not its titles" do
    before = profile.company_preferences_digest
    expect(profile.company_preferences_version).to eq(before.delete_prefix("sha256:")[0, 12])

    profile.update!(titles: [ "Sales Engineer" ])
    expect(profile.company_preferences_digest).to eq(before)
    profile.update!(places: [ "Portugal" ])
    expect(profile.company_preferences_digest).not_to eq(before)
    later { described_class.save!(profile.reload, company_models: "b2c") }
    expect(profile.reload.company_preferences_digest).not_to eq(before)
  end

  it "is saved by the operator's own client on their word, under company_preferences:write alone, which saves nothing else" do
    as_agent("agent:assistant", scopes: %w[company_preferences:write]) do
      described_class.save!(profile, given, actor: "agent:assistant")
      expect { profile.reload.update!(titles: [ "Sales" ]) }.to raise_error(Authority::Denied)
      expect { profile.resumes.create!(text: "A resume.", content_hash: Resume.digest("A resume.")) }.to raise_error(Authority::Denied)
    end

    event = AuditEvent.where(target: profile, action: "update").sole
    expect(event).to have_attributes(actor: "agent:assistant", reasoning: "Company preferences saved on the operator's word.")
    expect(event.credential.reload.scopes).to eq(%w[company_preferences:write])
    expect(Authority::HUMAN_ONLY).to include("Edit the search profile (its company preferences aside, which the operator's own client " \
                                             "may save on their word) or the resume")
  end
end
