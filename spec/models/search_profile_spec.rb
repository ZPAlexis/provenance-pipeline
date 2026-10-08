require "rails_helper"

RSpec.describe SearchProfile do
  it "takes its lists one per line, trimmed, each once whatever its case" do
    profile = described_class.new(titles_text: " Solutions Engineer \n\nRevOps\nsolutions engineer\r\n", places_text: "Brazil\nLATAM")

    expect(profile.titles).to eq([ "Solutions Engineer", "RevOps" ])
    expect(profile.places_text).to eq("Brazil\nLATAM")
    expect(profile.name).to eq("Main")
  end

  it "needs a title, and knows only the worker's work modes and levels" do
    profile = described_class.new(work_modes: [ "", "remote", "anywhere" ], levels: [ "senior", "mid" ])

    expect(profile).not_to be_valid
    expect(profile.errors[:titles]).to be_present
    expect(profile.errors[:work_modes].first).to match(/can only be remote, hybrid, or onsite/)
    expect(profile.errors[:levels].first).to match(/can only be entry, senior/)
    expect(profile.work_modes).to eq(%w[remote anywhere])
  end

  it "is sent to the worker under the contract's names" do
    profile = described_class.new(titles: [ "Solutions Engineer" ], excluded_words: [ "Intern" ], places: [ "Brazil" ],
                                  work_modes: [ "remote" ], levels: [ "senior" ])

    expect(profile.to_worker).to eq(titles: [ "Solutions Engineer" ], excluded: [ "Intern" ], places: [ "Brazil" ],
                                    work_modes: [ "remote" ], levels: [ "senior" ])
  end
end
