require "rails_helper"

RSpec.describe PageCheck do
  it "records one observation of a page" do
    expect(build(:page_check)).to be_valid
  end

  it "requires the run, the URL, and when it was checked" do
    %i[run_id url checked_at].each do |field|
      expect(build(:page_check, field => nil)).not_to be_valid, field.to_s
    end
  end

  it "accepts only known purposes, outcomes, and resolution steps" do
    expect(build(:page_check, purpose: "gossip")).not_to be_valid
    expect(build(:page_check, outcome: "maybe")).not_to be_valid
    expect(build(:page_check, step: "divination")).not_to be_valid
    expect(build(:page_check, step: nil)).to be_valid
  end

  it "rejects a negative listing count" do
    expect(build(:page_check, listing_count: -1)).not_to be_valid
  end

  it "selects the checks that found listings" do
    found = create(:page_check, listing_count: 4)
    create(:page_check, listing_count: 0)
    create(:page_check, outcome: "blocked", listing_count: nil)

    expect(described_class.yielding).to contain_exactly(found)
  end
end
