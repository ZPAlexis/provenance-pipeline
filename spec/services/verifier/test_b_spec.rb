require "rails_helper"

RSpec.describe Verifier::TestB do
  let(:company) { create(:company, :resolved, name: "Acme", domain: "acme.example") }

  def labeled(label, title: "RevOps Engineer", at: company)
    traits = { "verified_live" => :verified_live, "not_found" => :credible_negative }
    create(:posting, *Array(traits[label]), company: at, role_title: title,
                     enrichment: { "raw_verification" => label })
  end

  def snapshot(company, **attributes)
    create(:page_check, company: company, url: company.careers_page_url, read_via: "render+llm",
                        listings: [ { "title" => "RevOps Engineer" } ], listing_count: 1, **attributes)
  end

  def verdict(posting, value, method: "exact")
    { "posting_id" => posting.id, "verdict" => value, "method" => method, "reasoning" => "because" }
  end

  def evaluate(*verdicts) = described_class.new.evaluate([ { "verdicts" => verdicts } ])

  describe "labels" do
    it "comes from what the import recorded, so it survives the verifier replacing the verdict" do
      posting = labeled("not_found")
      posting.update!(verification_state: "verified_live")

      expect(described_class.label_for(posting)).to eq("not_found")
    end

    it "ignores a posting with no recognized verdict" do
      create(:posting, company: company, enrichment: { "raw_verification" => "probably_live" })

      expect(described_class.new.replay_targets).to be_empty
    end
  end

  describe "replay targets" do
    it "sends each company's labeled postings with the listings its watched page showed" do
      posting = labeled("verified_live")
      check = snapshot(company)

      expect(described_class.new.replay_targets).to eq([
        { id: company.id, label: "Acme", page_check_id: check.id, complete: true,
          listings: [ { "title" => "RevOps Engineer" } ],
          postings: [ { id: posting.id, title: "RevOps Engineer", location: posting.location } ] }
      ])
    end

    it "finds a board watched at its public address by the board its check read" do
      company.update!(careers_page_url: "https://job-boards.greenhouse.io/acme")
      labeled("verified_live")
      check = create(:page_check, company: company, url: "https://job-boards.greenhouse.io/acme/jobs/8054669",
                                  ats_vendor: "greenhouse", ats_board: "acme", read_via: "ats_api:greenhouse")

      expect(described_class.new.replay_targets.sole).to include(page_check_id: check.id, complete: true)
    end

    it "marks a page that showed part of its list as incomplete, unless its stated total says otherwise" do
      expect(described_class.complete?(build(:page_check, listings_incomplete: true))).to be(false)
      expect(described_class.complete?(build(:page_check, listing_count: 25, stated_total: 393))).to be(false)
      expect(described_class.complete?(build(:page_check, listing_count: 181, stated_total: 181, listings_incomplete: true)))
        .to be(true)
    end

    it "leaves out companies with no watched page or no stored check of it" do
      labeled("verified_live", at: create(:company, :resolution_candidate))
      labeled("verified_live")

      expect(described_class.new.replay_targets).to be_empty
    end
  end

  describe "hand checks" do
    before { snapshot(company) }

    it "counts a disagreement as agreement when the operator's own check found the label wrong" do
      posting = labeled("verified_live")
      Verifier::HandCheck.record!(posting, verdict: "not_found", note: "Not on the page.")

      kase = described_class.new.evaluate([ { "verdicts" => [ verdict(posting, "not_found", method: "none") ] } ]).cases.sole

      expect(kase).to be_agrees_by_hand
    end

    it "does not fail on a labeled negative the operator found open" do
      gone = labeled("not_found", title: "Designer")
      Verifier::HandCheck.record!(gone, verdict: "verified_live", note: "It is listed again.")

      report = described_class.new.evaluate([ { "verdicts" => [ verdict(gone, "verified_live") ] } ])

      expect(report.false_lives).to be_empty
      expect(report).to be_passed
    end
  end

  it "does not measure an aggregator's postings: they belong to other employers" do
    company.update!(kind: "aggregator")
    snapshot(company)
    labeled("verified_live")

    test = described_class.new

    expect([ test.verify_targets, test.replay_targets ]).to eq([ [], [] ])
    expect(test.evaluate([]).cases.sole.why_unmeasured).to eq("an aggregator: its postings belong to other employers")
  end

  describe "fresh targets" do
    it "sends each company's watched page and all its postings, so a passing run can be recorded as it is" do
      posting = labeled("verified_live")
      unlabeled = create(:posting, company: company, role_title: "Designer")

      expect(described_class.new.verify_targets.sole).to include(id: company.id, url: company.careers_page_url)
      expect(described_class.new.verify_targets.sole[:postings].pluck(:id)).to contain_exactly(posting.id, unlabeled.id)
    end

    it "says why a posting at a company with no watched page is not measured" do
      labeled("verified_live", at: create(:company, :resolution_candidate))

      expect(described_class.new.evaluate([]).cases.sole.why_unmeasured).to eq("the company has no watched page")
    end

    it "counts extraction on every page read and the near-miss call" do
      result = { "verdicts" => [], "checks" => [ { "llm" => { "cost_usd" => 0.01 } }, { "llm" => { "cost_usd" => 0.02 } } ],
                 "match_llm" => { "cost_usd" => 0.001 } }

      expect(described_class.new.evaluate([ result ]).cost_usd).to eq(0.031)
    end
  end

  describe "scoring" do
    before { snapshot(company) }

    it "scores agreement on postings that got a verdict" do
      live, gone = labeled("verified_live"), labeled("not_found", title: "Designer")

      report = evaluate(verdict(live, "verified_live"), verdict(gone, "not_found", method: "none"))

      expect([ report.agreeing, report.measured.size ]).to eq([ 2, 2 ])
      expect(report).to be_passed
    end

    it "reports an inconclusive check without scoring it" do
      posting = labeled("verified_live")

      report = evaluate(verdict(posting, nil, method: "none"))

      expect(report.measured).to be_empty
      expect(report.cases.sole.why_unmeasured).to start_with("inconclusive")
    end

    it "does not score an inaccessible label: it says nothing about the role" do
      create(:posting, company: company, enrichment: { "raw_verification" => "inaccessible" },
                       verification_state: "inaccessible", last_checked_at: Time.current)

      expect(described_class.new.evaluate([]).measured).to be_empty
    end

    # A closed role reported open is the costly mistake.
    it "fails on a labeled negative reported live, whatever the agreement" do
      postings = Array.new(9) { |n| labeled("verified_live", title: "Role #{n}") }
      gone = labeled("not_found", title: "Designer")

      report = evaluate(*postings.map { |p| verdict(p, "verified_live") }, verdict(gone, "verified_live"))

      expect(report.share).to eq(0.9)
      expect(report.false_lives.map(&:posting_id)).to eq([ gone.id ])
      expect(report).not_to be_passed
    end

    it "adds up the cost of near-miss calls" do
      report = described_class.new.evaluate([ { "verdicts" => [], "llm" => { "cost_usd" => 0.002, "input_tokens" => 900,
                                                                              "output_tokens" => 60 } } ])

      expect([ report.cost_usd, report.tokens ]).to eq([ 0.002, 960 ])
    end
  end
end
