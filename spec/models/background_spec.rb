require "rails_helper"

# The background's lines (4c): numbered across its three parts in order, as the resume's are within it, so a line
# cited by number names the same line for every reader, whichever parts it is given.
RSpec.describe Background do
  let(:profile) { SearchProfile.create!(titles: [ "Sales Engineer" ]) }
  let(:background) do
    described_class.of(profile, looking_for: " A long-term role.\r\n\r\nGrowing into Lead. ", role_preferences: nil,
                                not_on_resume: "Portuguese, native.\n  English, fluent. Lived in Canada.")
  end

  it "numbers every part's lines across the parts, each with its part, split as the resume's are" do
    expect(background.numbered_lines).to eq([
      [ 1, "A long-term role.", "looking_for" ], [ 2, "Growing into Lead.", "looking_for" ],
      [ 3, "Portuguese, native.", "not_on_resume" ], [ 4, "English, fluent.", "not_on_resume" ], [ 5, "Lived in Canada.", "not_on_resume" ]
    ])
    expect(background.lines_of("not_on_resume").map(&:first)).to eq([ 3, 4, 5 ])
    expect(background.words).to eq(13)
    expect(background.words("role_preferences")).to eq(0)
  end

  it "cites lines by number, B-prefixed or not, only among the parts a reader was given" do
    cited, dropped = background.cite([ "B4", 4, 1, "B9", "x" ], parts: [ "not_on_resume" ])

    expect(cited).to eq([ { "line" => 4, "text" => "English, fluent.", "part" => "not_on_resume" } ])
    expect(dropped).to eq(3) # line 1 is another part's, B9 and x name none
  end

  it "hashes each part, so a reader records what it read; the whole's version changes with any part" do
    other = described_class.of(profile, looking_for: "A long-term role.\nGrowing into Lead.", not_on_resume: "Something else.")

    expect(background.hash_of("looking_for")).to eq(other.hash_of("looking_for"))
    expect(background.hash_of("role_preferences")).to be_nil
    expect(background.version).to match(/\A\h{12}\z/)
    expect(background.version).not_to eq(other.version)
  end
end
