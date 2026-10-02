require "rails_helper"

RSpec.describe Verifier::Ingest do
  subject(:ingest) { described_class.new(run_id: "20260930T120000Z-resolve") }

  let(:company) { create(:company, name: "Acme Robotics", domain: "acme.example") }

  def llm(**overrides)
    { "model" => "claude-haiku-4-5-20251001", "settings" => {}, "purpose" => "extract", "prompt_version" => "abc123def456",
      "input_tokens" => 8_000, "output_tokens" => 900, "cost_usd" => 0.0125 }.merge(overrides.stringify_keys)
  end

  def check(url, **overrides)
    { "schema_version" => 2, "kind" => "page", "target_id" => company.id, "url" => url, "final_url" => url,
      "step" => "path_probe", "checked_at" => "2026-09-30T12:00:00+00:00", "outcome" => "ok", "method" => "render+llm",
      "listings" => [ { "title" => "RevOps Engineer" }, { "title" => "GTM Analyst" } ], "listing_count" => 2,
      "llm" => llm, "duration_ms" => 4_200 }.merge(overrides.stringify_keys)
  end

  def result(outcome, **overrides)
    { "schema_version" => 2, "kind" => "resolution", "target_id" => company.id, "outcome" => outcome,
      "checks" => [ check("https://acme.example/careers") ], "duration_ms" => 9_000 }.merge(overrides.stringify_keys)
  end

  def resolved(**overrides)
    result("resolved", careers_page_url: "https://acme.example/careers", method: "path_probe", confidence: "high", **overrides)
  end

  describe "a resolved company" do
    it "sets the watched page with how it was found and how sure we are" do
      expect(ingest.resolution(resolved)).to eq("resolved")

      expect(company.reload).to have_attributes(
        careers_page_url: "https://acme.example/careers", ats_type: "own_site", resolution_status: "resolved",
        resolution_method: "path_probe", resolution_confidence: "high", resolved_at: be_present
      )
    end

    it "names the ATS when the page was read through one" do
      ingest.resolution(resolved(careers_page_url: "https://jobs.lever.co/acme", method: "homepage_link",
                                 ats: { "vendor" => "lever", "board" => "acme" }))

      expect(company.reload.ats_type).to eq("lever")
    end

    it "keeps every check as evidence, with its listings and what its LLM call cost" do
      ingest.resolution(resolved(checks: [ check("https://acme.example/careers", listings_incomplete: true) ]))

      page_check = company.page_checks.sole
      expect(page_check).to have_attributes(
        run_id: "20260930T120000Z-resolve", purpose: "resolution", step: "path_probe", outcome: "ok",
        read_via: "render+llm", listing_count: 2, checked_at: Time.utc(2026, 9, 30, 12), duration_ms: 4_200,
        listings_incomplete: true, many_employers: false, single_job_posting: false, next_page_url: nil
      )
      expect(page_check.listings.pluck("title")).to eq([ "RevOps Engineer", "GTM Analyst" ])
      expect(page_check.llm_calls.sole).to have_attributes(
        purpose: "extract", model: "claude-haiku-4-5-20251001", prompt_version: "abc123def456",
        input_tokens: 8_000, output_tokens: 900, cost_usd: BigDecimal("0.0125")
      )
    end

    it "audits the change as the verifier, with the model that served it and the run it came from" do
      ingest.resolution(resolved)

      event = company.audit_events.sole
      expect(event).to have_attributes(actor: "agent:verifier", action: "update", model_version: "claude-haiku-4-5-20251001")
      expect(event.changes_made).to include("careers_page_url" => [ nil, "https://acme.example/careers" ],
                                            "resolution_status" => [ nil, "resolved" ])
      expect(event.reasoning).to include("path_probe", "high", "2 listings", "20260930T120000Z-resolve")
    end

    it "records the model's request settings beside it" do
      ingest.resolution(resolved(checks: [ check("https://acme.example/careers", llm: llm(settings: { "effort" => "low" })) ]))

      expect(company.audit_events.sole.model_version).to eq('claude-haiku-4-5-20251001 {"effort":"low"}')
    end

    it "says why the page on record was replaced" do
      company.update!(careers_page_url: "https://acme.example/old-careers")

      ingest.resolution(resolved)

      expect(company.audit_events.sole.reasoning).to include("replaces https://acme.example/old-careers")
    end
  end

  # A low-confidence find waits for a human; it never becomes the watched page.
  describe "a candidate" do
    it "is held apart from the watched page, with its evidence in the audit" do
      ingest.resolution(result("candidate", careers_page_url: "https://acme.example/life", method: "llm_link",
                                            confidence: "low", evidence: 'The LLM picked "Life at Acme".'))

      expect(company.reload).to have_attributes(
        careers_page_url: nil, resolution_status: "candidate", resolution_candidate_url: "https://acme.example/life",
        resolution_confidence: "low"
      )
      expect(company.audit_events.sole.reasoning).to include("held for a human", "Life at Acme")
    end
  end

  describe "a suggested kind" do
    def suggesting(kind)
      result("candidate", careers_page_url: "https://acme.example/jobs", method: "path_probe", confidence: "low",
                          kind_suggestion: kind, kind_evidence: "Its own page lists 30 roles at many employers.")
    end

    it "is held for the operator with its evidence" do
      ingest.resolution(suggesting("recruiter"))

      expect(company.reload).to have_attributes(kind: nil, kind_suggestion: "recruiter",
                                                kind_evidence: "Its own page lists 30 roles at many employers.")
    end

    it "never overrides a kind the operator set" do
      company.update!(kind: "employer")

      ingest.resolution(suggesting("aggregator"))

      expect(company.reload).to have_attributes(kind: "employer", kind_suggestion: nil)
    end
  end

  describe "a failure" do
    it "records why, and every check that was tried" do
      ingest.resolution(result("failed", failure: "not_found",
                                         checks: [ check("https://acme.example/", step: "homepage", llm: nil, listing_count: nil) ]))

      expect(company.reload).to have_attributes(resolution_status: "failed", resolution_failure: "not_found")
      expect(company.page_checks.sole.step).to eq("homepage")
      expect(company.audit_events.sole.model_version).to be_nil
    end
  end

  describe "an error of the worker's own" do
    it "keeps the checks and what they cost, and leaves the company alone" do
      ingest.resolution(result("error", reason: "unexpected:RuntimeError"))

      expect(company.reload.resolution_status).to be_nil
      expect(company.page_checks.count).to eq(1)
      expect(LlmCall.count).to eq(1)
      expect(company.audit_events).to be_empty
    end
  end

  describe "a result that breaks the contract" do
    it "is refused, writing nothing" do
      bad = resolved(confidence: "low")

      expect { ingest.resolution(bad) }.to raise_error(described_class::InvalidResult, /cannot be low confidence/)
      expect([ PageCheck.count, LlmCall.count, AuditEvent.count ]).to eq([ 0, 0, 0 ])
    end

    it "is refused when it names no known company" do
      expect { ingest.resolution(resolved(target_id: SecureRandom.uuid)) }
        .to raise_error(described_class::InvalidResult, /no such company/)
    end
  end

  it "writes a result whole or not at all" do
    allow(AuditEvent).to receive(:record_write!).and_raise("simulated failure")

    expect { ingest.resolution(resolved) }.to raise_error("simulated failure")
    expect([ PageCheck.count, company.reload.resolution_status ]).to eq([ 0, nil ])
  end

  it "writes no audit event when a result changes nothing" do
    ingest.resolution(result("failed", failure: "not_found"))

    expect { ingest.resolution(result("failed", failure: "not_found")) }.not_to change(AuditEvent, :count)
  end
end
