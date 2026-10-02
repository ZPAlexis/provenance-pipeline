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

  describe ".verification_errors" do
    def verification(**overrides)
      { "kind" => "verification", "target_id" => "c1", "url" => "https://acme.example/careers", "outcome" => "ok",
        "complete" => true, "checks" => [ check ],
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
end
