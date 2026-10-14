require "rails_helper"

RSpec.describe Verifier::ListChange do
  let(:company) { create(:company, :resolved, name: "Acme", domain: "acme.example", resolved_at: 30.days.ago) }

  def roles(*names) = names.map { |name| { "title" => name, "url" => "https://acme.example/jobs/#{name.parameterize}" } }

  # A verification run's first check, as the worker answered "was the whole list read?".
  def read(listings, at:, complete: true, url: company.careers_page_url, run_id: "r-#{at.to_i}")
    create(:page_check, company: company, purpose: "verification", step: nil, url: url, run_id: run_id, complete: complete,
                        checked_at: at, listings: listings, listing_count: listings.size)
  end

  let(:ten) { roles(*("A".."J").to_a) }

  it "is a lot when half the earlier list is gone, or half the later list is new, and at least 5 roles either way" do
    before = read(ten, at: 3.days.ago)

    expect(described_class.compare(before, read(ten.first(5), at: 2.days.ago))).to have_attributes(a_lot?: true) # 5 of 10 gone
    expect(described_class.compare(before, read(ten + roles("K", "L", "M"), at: 1.day.ago))).to have_attributes(a_lot?: false) # 3 new
    expect(described_class.compare(read(roles("A", "B"), at: 4.days.ago), read(roles("C", "D"), at: 4.days.ago + 1)))
      .to have_attributes(a_lot?: false) # wholly different, but only 4 roles moved
  end

  it "reads roles by their own link, tracking parameters and case aside" do
    before = read(ten, at: 2.days.ago)
    tagged = ten.map { |role| role.merge("url" => "#{role['url'].sub('acme.example/jobs', 'acme.example/Jobs')}?utm_source=linkedin") }

    expect(described_class.compare(before, read(tagged, at: 1.day.ago))).to have_attributes(gone: 0, added: 0)
  end

  it "compares only whole reads of the same page, since the careers page was last settled" do
    read(ten, at: 40.days.ago) # before the page was settled
    read(ten, at: 3.days.ago)
    read(ten.first(2), at: 2.days.ago, complete: false) # part of a list: never compared
    read(roles("X"), at: 2.days.ago, url: "https://other.example/jobs") # another page: compared only with itself
    latest = read(ten.first(4), at: 1.day.ago)

    change = described_class.latest(company)

    expect(change).to have_attributes(after: latest, gone: 6, added: 0, before_size: 10, after_size: 4)
    expect(described_class.since(2.days.ago).map(&:after)).to eq([ latest ])
    expect(described_class.since(Time.current)).to be_empty
  end
end
