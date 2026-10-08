require "rails_helper"

RSpec.describe Verifier::ResultContract do
  def check(**overrides)
    { "url" => "https://acme.example/careers", "checked_at" => "2026-09-30T12:00:00+00:00", "outcome" => "ok",
      "step" => "path_probe", "listing_count" => 1, "listings" => [ { "title" => "RevOps Engineer" } ] }
      .merge(overrides.stringify_keys)
  end

  def resolution(**overrides)
    { "kind" => "resolution", "target_id" => "c1", "outcome" => "resolved",
      "careers_page_url" => "https://acme.example/careers", "method" => "path_probe", "confidence" => "high",
      "checks" => [ check ] }.merge(overrides.stringify_keys)
  end

  def errors(result) = described_class.resolution_errors(result)

  it "accepts a well-formed result" do
    expect(errors(resolution)).to be_empty
  end

  it "accepts a failure with no page" do
    expect(errors(resolution(outcome: "failed", failure: "blocked", careers_page_url: nil, method: nil, confidence: nil))).to be_empty
  end

  it "refuses what is not a resolution" do
    expect(errors("nonsense")).to eq([ "not an object" ])
    expect(errors(resolution(kind: "page"))).to include("kind must be resolution")
    expect(errors(resolution(outcome: "maybe"))).to include(/unknown outcome/)
  end

  it "refuses a page that is not a web address" do
    expect(errors(resolution(careers_page_url: "javascript:alert(1)"))).to include(/http\(s\) URL/)
  end

  # Low confidence is exactly what a human confirms.
  it "refuses a low-confidence resolution, and a candidate that is not low" do
    expect(errors(resolution(confidence: "low"))).to include(/cannot be low/)
    expect(errors(resolution(outcome: "candidate", confidence: "high"))).to include(/cannot be high/)
  end

  it "refuses a kind suggestion it does not know" do
    expect(errors(resolution(outcome: "candidate", confidence: "low", kind_suggestion: "agency"))).to include(/unknown kind suggestion/)
  end

  it "refuses failure reasons only Rails decides" do
    expect(errors(resolution(outcome: "failed", failure: "rejected"))).to include(/unknown failure/)
  end

  it "names the check that breaks the contract" do
    bad = resolution(checks: [ check, check(checked_at: "yesterday", listing_count: -1, llm: { "model" => "m" }) ])

    expect(errors(bad)).to include(
      "check 2: checked_at must be an ISO 8601 time",
      "check 2: listing_count must be a count",
      "check 2: llm prompt_version is missing"
    )
  end

  it "refuses a reused read that does not name the read it reused, or a read time that is not a time" do
    expect(described_class.page_errors(check(method: "reused"))).to include("a reused read must name the read it reused")
    expect(described_class.page_errors(check(method: "reused", reused_from: "pc1", listings_read_at: "2026-09-28T12:00:00Z")))
      .to be_empty
    expect(described_class.page_errors(check(listings_read_at: "last week"))).to include("listings_read_at must be an ISO 8601 time")
  end

  describe ".board_errors" do
    def board(**overrides)
      { "kind" => "board", "target_id" => "c1", "outcome" => "adopted", "board" => { "vendor" => "ashby", "board" => "acme" },
        "overlap" => 0.95, "evidence" => "ashby/acme lists 95% of the roles." }.merge(overrides.stringify_keys)
    end

    it "accepts a well-formed board, and an empty search" do
      expect(described_class.board_errors(board)).to be_empty
      expect(described_class.board_errors(board(outcome: "none", board: nil, overlap: 0.0, evidence: nil))).to be_empty
    end

    it "refuses an adoption below the overlap a board must show, or without its evidence" do
      expect(described_class.board_errors(board(overlap: 0.89))).to include(/adopted with only 89%/)
      expect(described_class.board_errors(board(evidence: ""))).to include("evidence is missing")
    end

    it "refuses an unknown outcome, vendor, or overlap" do
      expect(described_class.board_errors(board(outcome: "maybe"))).to include(/unknown outcome "maybe"/)
      expect(described_class.board_errors(board(board: { "vendor" => "taleo", "board" => "acme" })))
        .to include("board must name a known vendor and its board")
      expect(described_class.board_errors(board(overlap: 1.5))).to include("overlap must be a share from 0 to 1")
    end
  end

  describe ".verification_errors" do
    def verification(**overrides)
      { "kind" => "verification", "target_id" => "c1", "url" => "https://acme.example/careers", "outcome" => "ok",
        "complete" => true, "listing_count" => 1, "checks" => [ check ],
        "verdicts" => [ { "posting_id" => "p1", "verdict" => "not_found", "method" => "none", "reasoning" => "Not there." } ] }
        .merge(overrides.stringify_keys)
    end

    it "accepts a well-formed verification" do
      expect(described_class.verification_errors(verification)).to be_empty
    end

    # The rule that keeps a role on page two from being marked closed, enforced at the write path too.
    it "refuses a negative from part of a list" do
      expect(described_class.verification_errors(verification(complete: false))).to include("verdict 1: not_found from part of a list")
    end

    # Found in the first real run: a careers portal down for maintenance, read as a whole list of none.
    it "refuses a negative from a read that found no roles, unless a page said it has none or an ATS API listed none" do
      empty = verification(listing_count: 0, checks: [ check(listing_count: 0, listings: []) ])

      expect(described_class.verification_errors(empty)).to include(/listed no roles and did not say it has none/)
      expect(described_class.verification_errors(verification(listing_count: 0, checks: [ check(listing_count: 0, explicit_no_openings: true) ]))).to be_empty
      expect(described_class.verification_errors(verification(listing_count: 0, checks: [ check(listing_count: 0, method: "ats_api:lever") ]))).to be_empty
    end

    it "accepts no verdict (inconclusive) from part of a list" do
      inconclusive = [ { "posting_id" => "p1", "verdict" => nil, "method" => "none", "reasoning" => "Partial." } ]

      expect(described_class.verification_errors(verification(complete: false, verdicts: inconclusive))).to be_empty
    end

    it "refuses unknown verdicts and methods" do
      odd = [ { "posting_id" => "p1", "verdict" => "closed", "method" => "guess", "reasoning" => "Hm." } ]

      expect(described_class.verification_errors(verification(verdicts: odd)))
        .to include(/unknown verdict "closed"/, /unknown method "guess"/)
    end
  end

  describe ".suggestion_errors" do
    def fit(**overrides)
      { "listing_index" => 0, "listing" => { "title" => "Solutions Engineer" }, "title" => "Solutions Engineer",
        "level" => nil, "place" => "Brazil", "work_mode" => "remote", "suggested" => true, "ruled_out" => nil, "notes" => [],
        "reasoning" => "Its title holds every word of \"Solutions Engineer\"." }.merge(overrides.transform_keys(&:to_s))
    end

    def suggestion(roles, listed: {}) = { "kind" => "suggestion", "target_id" => "c1", "outcome" => "ok", "weighed" => 3, "roles" => roles, "listed" => listed }

    it "accepts roles suggested, or ruled out by one rule" do
      expect(described_class.suggestion_errors(suggestion([ fit, fit(suggested: false, ruled_out: "place") ]))).to be_empty
    end

    it "accepts a role naming the posting it already is, and refuses a listing of postings that is not one" do
      on_record = suggestion([ fit(on_record: "p1") ], listed: { "p1" => 0, "p2" => 4 })
      expect(described_class.suggestion_errors(on_record)).to be_empty

      odd = suggestion([ fit(on_record: "") ], listed: { "p1" => -1 })
      expect(described_class.suggestion_errors(odd)).to include("listed must map posting ids to listing indexes",
                                                                "role 1: on_record must name a posting")
    end

    it "refuses a role both suggested and ruled out, or neither, and names it" do
      result = suggestion([ fit, fit(ruled_out: "place"), fit(suggested: false), fit(suggested: "yes") ])

      expect(described_class.suggestion_errors(result)).to eq(
        [ "role 2: a suggested role cannot be ruled out", "role 3: unknown rule nil", "role 4: suggested must be true or false" ]
      )
    end

    it "refuses levels, notes, and roles it does not know" do
      result = suggestion([ fit(level: "mid", work_mode: "anywhere", notes: [ "salary_not_stated" ], listing: { "title" => nil }, reasoning: "") ])

      expect(described_class.suggestion_errors(result)).to include(
        /unknown level "mid"/, /unknown work mode "anywhere"/, /unknown notes/, /listing must have a title/, /reasoning is missing/
      )
      expect(described_class.suggestion_errors(suggestion(nil).merge("kind" => "board"))).to include("kind must be suggestion", "roles must be a list")
    end
  end
end
