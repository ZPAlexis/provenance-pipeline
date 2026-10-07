require "rails_helper"

RSpec.describe Verifier::JobUrls do
  let(:company) { create(:company, :resolved) }
  let(:posting) { create(:posting, :verified_live, company: company, role_title: "Data Engineer") }

  def listing(title, url = nil) = { "title" => title, "url" => url }

  # A run's pages as the worker recorded them, the posting's match on the first.
  def run(*pages, index:, verdict: "verified_live", title: "Data Engineer", run_id: "20261005T120000Z-verify",
          method: "exact", at: Time.current)
    pages.each_with_index.map do |listings, n|
      matches = n.zero? ? [ { "posting_id" => posting.id, "verdict" => verdict, "method" => method, "listing_index" => index,
                              "reasoning" => "The page lists \"#{title}\"." } ] : []
      create(:page_check, company: company, purpose: "verification", step: nil, run_id: run_id, url: "#{company.careers_page_url}?page=#{n + 1}",
                          listings: listings, matches: matches, checked_at: at)
    end
  end

  it "learns a posting's own page from the listing it matched, across the pages of the run" do
    run([ listing("RevOps Engineer", "https://acme.example/jobs/1"), listing("Designer", "https://acme.example/jobs/2") ],
        [ listing("Designer", "https://acme.example/jobs/2"), listing("Data Engineer", "https://acme.example/jobs/3") ],
        index: 2) # the second page's repeat of "Designer" was not counted again

    expect(described_class.backfill!).to eq(1)
    expect(posting.reload.job_url).to eq("https://acme.example/jobs/3")
    event = posting.audit_events.sole
    expect(event).to have_attributes(actor: "agent:verifier")
    expect(event.reasoning).to include("learned from the listing it matched (\"Data Engineer\") in check")
  end

  it "learns nothing when the listing has no link, the match was not live, or the index does not name its listing" do
    run([ listing("Data Engineer") ], index: 0)
    run([ listing("Data Engineer", "https://acme.example/jobs/3") ], index: 0, verdict: "not_found", run_id: "r2")
    expect(described_class.backfill!).to eq(0)

    run([ listing("Designer", "https://acme.example/jobs/2") ], index: 0, run_id: "r3") # reasoning names another title
    expect(described_class.backfill!).to eq(0)
    expect(posting.reload.job_url).to be_nil
  end

  # Found with Baker Hughes (2026-10-07): a link learned from an old, wrong match
  # kept a role it no longer had "still listed" through link-first matching.
  it "learns nothing when a later check found the role gone, though an earlier one matched it" do
    run([ listing("Data Engineer", "https://acme.example/jobs/3") ], index: 0, at: 2.days.ago, run_id: "r1")
    run([ listing("Designer", "https://acme.example/jobs/2") ], index: nil, verdict: "not_found", at: 1.day.ago, run_id: "r2")

    expect(described_class.backfill!).to eq(0)
  end

  it "learns nothing from a near-miss the LLM judged the same role" do
    run([ listing("Data Engineer II", "https://acme.example/jobs/3") ], index: 0, method: "llm", title: "Data Engineer II")

    expect(described_class.backfill!).to eq(0)
  end

  it "leaves a posting that already knows its page, or is dismissed, alone" do
    run([ listing("Data Engineer", "https://acme.example/jobs/3") ], index: 0)
    posting.update!(job_url: "https://acme.example/jobs/old")
    expect(described_class.backfill!).to eq(0)
    expect(posting.reload.job_url).to eq("https://acme.example/jobs/old")

    posting.update!(job_url: nil, tracking: "dismissed")
    expect(described_class.backfill!).to eq(0)
  end
end
