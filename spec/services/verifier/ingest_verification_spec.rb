require "rails_helper"

RSpec.describe Verifier::Ingest, "#verification" do
  subject(:ingest) { described_class.new(run_id: "20261001T120000Z-verify") }

  let(:company) { create(:company, :resolved, name: "Acme", domain: "acme.example") }
  let(:posting) do
    create(:posting, :credible_negative, company: company, role_title: "RevOps Engineer",
                                         last_checked_at: Time.utc(2026, 9, 30, 12), enrichment: { "raw_verification" => "not_found" })
  end

  let(:extract_llm) do
    { "model" => "claude-haiku-4-5-20251001", "settings" => {}, "purpose" => "extract", "prompt_version" => "e1",
      "input_tokens" => 5_000, "output_tokens" => 400, "cost_usd" => 0.007 }
  end

  def page(**overrides)
    { "url" => company.careers_page_url, "final_url" => company.careers_page_url, "checked_at" => "2026-10-01T12:00:00+00:00",
      "outcome" => "ok", "method" => "render+llm", "listing_count" => 12, "listings" => [ { "title" => "RevOps Engineer" } ],
      "llm" => extract_llm }.merge(overrides.stringify_keys)
  end

  def verdict(value, **overrides)
    { "posting_id" => posting.id, "verdict" => value, "method" => value == "verified_live" ? "exact" : "none",
      "listing_index" => 0, "listing" => { "title" => "RevOps Engineer", "work_mode" => "remote" },
      "reasoning" => 'The page lists "RevOps Engineer".' }.merge(overrides.stringify_keys)
  end

  def result(*verdicts, complete: true, outcome: "ok", checks: [ page ], **extra)
    { "kind" => "verification", "target_id" => company.id, "url" => company.careers_page_url, "outcome" => outcome,
      "complete" => complete, "listing_count" => 12, "checks" => checks, "verdicts" => verdicts }.merge(extra.stringify_keys)
  end

  it "writes a verdict that changes, audited as the verifier, replacing the imported one" do
    tally = ingest.verification(result(verdict("verified_live", location_note: "Listed for Poland; the posting says Brazil.")))

    expect(tally).to eq(written: 1)
    expect(posting.reload).to have_attributes(
      verification_state: "verified_live", roles_listed_count: 12, work_mode: "remote",
      last_checked_at: Time.utc(2026, 10, 1, 12)
    )
    event = posting.audit_events.where(actor: "agent:verifier").sole
    expect(event).to have_attributes(action: "update", model_version: "claude-haiku-4-5-20251001")
    expect(event.changes_made["verification_state"]).to eq([ "not_found", "verified_live" ])
    expect(event.reasoning).to include('The page lists "RevOps Engineer".', "Listed for Poland",
                                       "12 roles read on #{company.careers_page_url}, the whole list.", "Run 20261001T120000Z-verify.")
    expect(posting.enrichment["raw_verification"]).to eq("not_found") # the imported label survives
  end

  it "confirms an unchanged verdict without an audit event, refreshing the check time and what it observed" do
    expect { ingest.verification(result(verdict("not_found", listing: nil))) }.not_to change(AuditEvent, :count)

    expect(posting.reload).to have_attributes(verification_state: "not_found", roles_listed_count: 12,
                                              last_checked_at: Time.utc(2026, 10, 1, 12))
  end

  it "leaves the posting alone on an inconclusive check, and keeps why on the page check" do
    before = posting.attributes

    tally = ingest.verification(result(verdict(nil, reasoning: "Not among the 25 roles read; inconclusive."), complete: false))

    expect(tally).to eq(inconclusive: 1)
    expect(posting.reload.attributes).to eq(before)
    expect(company.page_checks.sole.matches.sole).to include("posting_id" => posting.id, "verdict" => nil,
                                                             "reasoning" => "Not among the 25 roles read; inconclusive.")
  end

  it "writes inaccessible when the site refused us, with no count observed" do
    blocked = page(outcome: "inaccessible", reason: "http_403", listing_count: nil, listings: [], llm: nil)
    ingest.verification(result(verdict("inaccessible", listing: nil, reasoning: "The watched page could not be read (http_403)."),
                               outcome: "inaccessible", complete: false, checks: [ blocked ]))

    expect(posting.reload).to have_attributes(verification_state: "inaccessible", roles_listed_count: nil)
  end

  it "keeps every page read and every LLM call, the near-miss call included" do
    second = page(url: "#{company.careers_page_url}?page=2", final_url: nil)
    match_llm = extract_llm.merge("purpose" => "match", "prompt_version" => "m1", "cost_usd" => 0.001)

    ingest.verification(result(verdict("verified_live"), checks: [ page, second ], match_llm: match_llm))

    expect(company.page_checks.pluck(:purpose).uniq).to eq([ "verification" ])
    expect(company.page_checks.count).to eq(2)
    expect(LlmCall.pluck(:purpose)).to contain_exactly("extract", "extract", "match")
  end

  it "refuses a negative read from part of a list, writing nothing" do
    expect { ingest.verification(result(verdict("not_found"), complete: false)) }
      .to raise_error(described_class::InvalidResult, /not_found from part of a list/)
    expect(PageCheck.count).to eq(0)
  end

  it "refuses a verdict on another company's posting" do
    stranger = create(:posting)

    expect { ingest.verification(result(verdict("verified_live", posting_id: stranger.id))) }
      .to raise_error(described_class::InvalidResult, /not this company's/)
  end
end
