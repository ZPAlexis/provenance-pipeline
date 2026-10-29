require "rails_helper"
require Rails.root.join("mcp/provenance_mcp")
ProvenanceMcp.tools

# How the search is going, through MCP (3.3 step 3). A read tool's call leaves the test's transaction read-only: each
# example writes before its first call.
RSpec.describe "Analytics through MCP" do
  let!(:company) { create(:company, :resolved, name: "Acme", domain: "acme.example") }

  def call(**arguments) = ProvenanceMcp::Tools::AnalyticsReport.call(**arguments, server_context: nil)

  def said(response) = response.content.sole[:text]

  # Each write a minute after the one before, as a person makes them (WSL's host steps the clock back now and then).
  def later(&block)
    @clock = (@clock || Time.current.beginning_of_day) + 1.minute
    travel_to(@clock, &block)
  end

  # Five applications started at Interested ten days ago, three applied to, one of those rejected; a role read and
  # confirmed listed, at a cost; a recommendation pending.
  def record
    5.times.map do |n|
      role = create(:posting, company: company, role_title: "Role #{n}")
      application = later { Pipeline.start!(role, on: 10.days.ago.to_date) }
      later { Pipeline.move!(application, "applied", on: 8.days.ago.to_date) } if n < 3
      application
    end.tap { |made| later { Pipeline.move!(made.first, "rejected", on: 1.day.ago.to_date) } }
    listed = create(:posting, :verified_live, company: company, role_title: "Listed")
    create(:audit_event, actor: "agent:verifier", target: listed, occurred_at: 2.days.ago,
                         changes_made: { "verification_state" => [ nil, "verified_live" ], "last_checked_at" => [ nil, 2.days.ago.iso8601 ] })
    read = create(:page_check, company: company, purpose: "verification", checked_at: 2.days.ago,
                               matches: [ { "posting_id" => listed.id, "verdict" => "verified_live" } ])
    create(:llm_call, page_check: read, cost_usd: 0.02, called_at: 2.days.ago)
  end

  it "says how the search is going, section by section, as the Analytics page does" do
    record

    text = said(call)

    expect(text).to start_with("Pipeline (every application): 5 applications.\nHow far they get")
    expect(text).to include("  Interested: 5", "  Applied: 3, 60% of those at the stage before",
                            "  Screening: 0, too few at the stage before to say (3)\n  Interviewing: 0\n",
                            "  Interested: 5 times there, median 2, longest 10, 2 still there",
                            "  Applied: 3 times there, median 8, longest 8, 2 still there",
                            "How they end: accepted, 0 of 1 closed (too few to say); an offer, 0 of 3 applied to (too few to say).",
                            "Open now: Interested 2 (median 10 days there, longest 10); Applied 2",
                            "\n\nThe watch (every role):", "none seen gone yet; 1 listed still, median 2 days so far (longest 2).",
                            "1 role matched by the reads, 0 answers changed",
                            "of 6 tracked roles, 1 checked in the last 14 days, 0 longer ago, 5 never.",
                            "\n\nThe agents (all time):", "What the AI cost: $0.020 over 1 call.",
                            "extract on claude-haiku-4-5-20251001: 1 call, $0.020 (100.0%), 10,000 tokens in, 2,000 out",
                            "1 verification read, 1 needing the AI, $0.020 in all; $0.020 a read, $0.020 a role confirmed listed (1 role).",
                            "  none made", "  agent:verifier: 1 write, 0 refused, 0 credentials issued", "  operator: 9 writes, 0 refused")
  end

  it "gives one section, for a period, and refuses a day it can't read" do
    record

    watch = said(call(section: "watch"))
    since = said(call(section: "pipeline", since: Date.tomorrow.to_s))

    expect(watch).to start_with("The watch (every role):").and(not_include("Pipeline", "The agents"))
    expect(since).to eq("Pipeline (the applications started since #{Date.tomorrow}): none yet.\n" \
                        "Open now: Interested 2 (median 10 days there, longest 10); Applied 2 (median 8 days there, longest 8). " \
                        "1 tracked role still listed has no application.")
    refused = call(since: "last week")
    expect(refused.error?).to be(true)
    expect(said(refused)).to eq('Since is a day as YYYY-MM-DD, not "last week".')
  end

  it "keeps its sections in step with the app's, and the server names it" do
    schema = ProvenanceMcp::Tools::AnalyticsReport.to_h.dig(:inputSchema, :properties)

    expect(schema.dig(:section, :enum)).to eq(Analytics::Text::SECTIONS)
    expect(ProvenanceMcp::INSTRUCTIONS).to include("use get_analytics", "too few to say")
  end
end
