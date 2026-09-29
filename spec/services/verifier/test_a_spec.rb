require "rails_helper"

RSpec.describe Verifier::TestA do
  def company_with_recorded(count, name: "Company")
    company = create(:company, :with_careers_page, name: name)
    create(:posting, :credible_negative, company: company, roles_listed_count: count)
    company
  end

  def result(company, count, outcome: "ok", **extra)
    { "target_id" => company.id, "outcome" => outcome, "listing_count" => count }.merge(extra.stringify_keys)
  end

  def evaluate(results)
    described_class.new.evaluate(results)
  end

  describe "#targets" do
    it "checks every company with a careers page, and no others" do
      with_page = company_with_recorded(12, name: "Acme")
      create(:company)

      expect(described_class.new.targets).to eq([
        { id: with_page.id, url: with_page.careers_page_url, label: "Acme", domain: with_page.domain, name: "Acme" }
      ])
    end
  end

  # Test A measures whether the renderer can read pages. A page robots.txt keeps
  # us off says nothing about that, so it is reported but not scored.
  describe "pages robots.txt keeps us off" do
    it "leaves them out of the pass criterion" do
      blocked = company_with_recorded(0)
      read = company_with_recorded(10)

      report = evaluate([ result(blocked, nil, outcome: "blocked", reason: "robots_disallowed"), result(read, 10) ])

      expect(report.blocked.map(&:id)).to eq([ blocked.id ])
      expect(report.measured.map(&:id)).to eq([ read.id ])
      expect(report).to be_passed
    end

    it "scores a blocked page normally when its listings were read from the company's ATS board instead" do
      fallback = company_with_recorded(10)

      report = evaluate([ result(fallback, 11, method: "ats_api:lever", reason: "robots_disallowed_ats_fallback") ])

      expect(report.blocked).to be_empty
      expect(report.pages.first).to have_attributes(yielded?: true, ats_fallback?: true)
      expect(report).to be_passed
    end

    it "does not pass on blocked pages alone" do
      blocked = company_with_recorded(10)

      expect(evaluate([ result(blocked, nil, outcome: "blocked", reason: "robots_disallowed") ])).not_to be_passed
    end
  end

  describe "recorded counts" do
    it "takes the largest count recorded across a company's checked postings" do
      company = company_with_recorded(12)
      create(:posting, :verified_live, company: company, roles_listed_count: 14)

      expect(evaluate([]).pages.first.recorded).to eq(14)
    end

    it "is unknown when no count was recorded" do
      company = create(:company, :with_careers_page)
      create(:posting, :verified_live, company: company, roles_listed_count: nil)

      expect(evaluate([]).pages.first.recorded).to be_nil
    end
  end

  describe "tolerance: within 25% or 3, whichever is larger" do
    [
      [ 12, 15, true ],   # off by 3, the floor
      [ 12, 16, false ],
      [ 112, 85, true ],  # off by 27, under 25% of 112
      [ 112, 83, false ]
    ].each do |recorded, extracted, within|
      it "#{within ? 'accepts' : 'flags'} #{extracted} extracted against #{recorded} recorded" do
        company = company_with_recorded(recorded)

        expect(evaluate([ result(company, extracted) ]).pages.first.within_tolerance?).to be(within)
      end
    end
  end

  describe "passing" do
    it "passes when every page yields listings and at least 80% of counts agree" do
      companies = [ 10, 10, 10, 10, 10 ].map { |count| company_with_recorded(count) }
      results = companies.each_with_index.map { |company, i| result(company, i.zero? ? 30 : 10) }

      report = evaluate(results)

      expect([ report.agreeing, report.comparable.size ]).to eq([ 4, 5 ])
      expect(report).to be_passed
    end

    it "fails when agreement falls under 80%" do
      companies = [ 10, 10, 10, 10, 10 ].map { |count| company_with_recorded(count) }
      results = companies.each_with_index.map { |company, i| result(company, i < 2 ? 30 : 10) }

      expect(evaluate(results)).not_to be_passed
    end

    # The headline case: a page recorded as 0 roles must now yield listings.
    it "fails while a known parse failure still yields nothing" do
      known_failure = company_with_recorded(0)
      other = company_with_recorded(10)

      expect(evaluate([ result(known_failure, 0), result(other, 10) ])).not_to be_passed
      expect(evaluate([ result(known_failure, 4), result(other, 10) ])).to be_passed
    end

    it "fails when a page could not be read, or was never checked" do
      blocked = company_with_recorded(10)
      unchecked = company_with_recorded(10)

      report = evaluate([ result(blocked, nil, outcome: "inaccessible", reason: "bot_challenge") ])

      expect(report.pages.map(&:yielded?)).to eq([ false, false ])
      expect(report).not_to be_passed
    end
  end

  it "notes a page that itself says it has no openings" do
    company = company_with_recorded(5)

    page = evaluate([ result(company, 0, explicit_no_openings: true) ]).pages.first

    expect(page).to have_attributes(yielded?: false, says_no_openings?: true)
  end

  it "totals what the run's LLM calls cost" do
    first = company_with_recorded(10)
    second = company_with_recorded(10)
    llm = { "input_tokens" => 10_000, "output_tokens" => 2_000, "cost_usd" => 0.02 }

    report = evaluate([ result(first, 10, llm: llm), result(second, 10) ])

    expect(report.tokens).to eq(12_000)
    expect(report.cost_usd).to eq(0.02)
  end
end
