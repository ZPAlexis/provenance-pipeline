require "rails_helper"

# The agents (3.3 step 2): what the AI cost, how the recommendations came out, and what each actor wrote.
RSpec.describe Analytics::Agents do
  let!(:company) { create(:company, :resolved, name: "Acme", domain: "acme.example") }
  let(:day) { ->(n) { Time.utc(2026, 10, 1, 12) + n.days } }

  def call(on, purpose: "extract", model: "claude-haiku-4-5-20251001", cost: 0.02, read: nil)
    create(:llm_call, page_check: read, purpose: purpose, model: model, cost_usd: cost, called_at: day.(on), input_tokens: 1_000, output_tokens: 100)
  end

  it "says what the AI cost by day with a running total, and by purpose and model with each one's share" do
    call(0, cost: 0.03)
    call(0, purpose: "match", cost: 0.01)
    call(2, purpose: "draft", model: "claude-opus-5-5", cost: 0.06)

    report = described_class.report

    expect(report.days.map(&:to_h)).to eq([ { day: Date.new(2026, 10, 1), calls: 2, cost: 0.04, running: 0.04 },
                                            { day: Date.new(2026, 10, 3), calls: 1, cost: 0.06, running: 0.1 } ])
    expect(report.spend.map { |spend| [ spend.purpose, spend.model, spend.calls, spend.cost, spend.share.round(2) ] })
      .to eq([ [ "draft", "claude-opus-5-5", 1, 0.06, 0.6 ], [ "extract", "claude-haiku-4-5-20251001", 1, 0.03, 0.3 ],
               [ "match", "claude-haiku-4-5-20251001", 1, 0.01, 0.1 ] ])
    expect(report.cost).to be_within(1e-9).of(0.1)
    expect(described_class.report(since: day.(1).to_date).days.map(&:running)).to eq([ 0.06 ]) # the running total starts with the period
  end

  # The left join: a read through a board's API needs no AI, and still counts as a read.
  it "costs the verification reads, those that needed no AI included, and per role they confirmed listed" do
    with_ai = create(:page_check, company: company, purpose: "verification", checked_at: day.(0),
                                  matches: [ { "posting_id" => "a", "verdict" => "verified_live" }, { "posting_id" => "b", "verdict" => "not_found" } ])
    call(0, cost: 0.03, read: with_ai)
    call(0, purpose: "match", cost: 0.01, read: with_ai)
    create(:page_check, company: company, purpose: "verification", read_via: "ats_api:greenhouse", checked_at: day.(1),
                        matches: [ { "posting_id" => "a", "verdict" => "verified_live" }, { "posting_id" => "c", "verdict" => "verified_live" } ])
    resolving = create(:page_check, company: company, purpose: "resolution", checked_at: day.(1))
    call(1, purpose: "resolve", cost: 0.05, read: resolving) # finding a page: not a verification read

    reads = described_class.report.reads

    expect(reads.to_h).to eq(reads: 2, with_ai: 1, cost: 0.04, confirmed: 2)
    expect([ reads.per_read, reads.per_confirmed ]).to eq([ 0.02, 0.02 ])
    expect(described_class.report(since: day.(1).to_date).reads.to_h).to eq(reads: 1, with_ai: 0, cost: 0.0, confirmed: 2)
  end

  it "shows how the recommendations came out by kind, with agreement once enough were decided" do
    item = lambda do |kind, status, taken: nil, at: day.(0)|
      recommendation = { "decision" => "leave", "confidence" => "high", "reasoning" => "x", "at" => at.iso8601, "by" => "agent:assistant" }
      recommendation["taken"] = { "decision" => taken, "at" => at.iso8601 } if taken
      Authority.unchecked do
        ReviewItem.create!(company: company, subject: company, kind: kind, status: status, evidence: "seen", evidence_key: SecureRandom.hex(4),
                           raised_by: "agent:verifier", proposal: "leave", recommendation: recommendation)
      end
    end
    5.times { item.("partial_list", "left", taken: "leave") }
    item.("partial_list", "done", taken: "set_page")
    item.("no_careers_page", "open", at: day.(3))
    item.("no_careers_page", "left") # settled before the operator acted

    agreement = described_class.report.agreement

    expect(agreement.map(&:to_h)).to eq([ { kind: "no_careers_page", agreed: 0, differed: 0, resolved: 1, pending: 1 },
                                          { kind: "partial_list", agreed: 5, differed: 1, resolved: 0, pending: 0 } ])
    expect(agreement.map(&:rate)).to eq([ nil, 83 ])
    expect(described_class.report(since: day.(2).to_date).agreement.map(&:to_h))
      .to eq([ { kind: "no_careers_page", agreed: 0, differed: 0, resolved: 0, pending: 1 } ])
  end

  it "says what each actor wrote and was refused, every human as the operator, beside the credentials issued" do
    create(:audit_event, actor: "agent:verifier", occurred_at: day.(0))
    create(:audit_event, actor: "agent:verifier", occurred_at: day.(1))
    create(:audit_event, actor: "agent:suggester", action: "denied", occurred_at: day.(1))
    create(:audit_event, actor: AuditEvent::OPERATOR, occurred_at: day.(1))
    create(:audit_event, actor: "human:earlier", occurred_at: day.(0))
    travel_to(day.(1)) { AgentCredential.issue!(actor: "agent:fit_scorer", scopes: %w[fit:write], purpose: "x", ttl: 1.hour, issued_by: AuditEvent::OPERATOR) }

    actors = described_class.report.actors

    expect(actors.map(&:to_h)).to eq([ { actor: "agent:verifier", writes: 2, refused: 0, credentials: 0 },
                                       { actor: "operator", writes: 2, refused: 0, credentials: 0 },
                                       { actor: "agent:fit_scorer", writes: 0, refused: 0, credentials: 1 },
                                       { actor: "agent:suggester", writes: 0, refused: 1, credentials: 0 } ])
    expect(described_class.report(since: day.(1).to_date).actors.map { |row| [ row.actor, row.writes ] })
      .to include([ "agent:verifier", 1 ], [ "operator", 1 ])
  end
end
