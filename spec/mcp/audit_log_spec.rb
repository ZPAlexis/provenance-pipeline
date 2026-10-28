require "rails_helper"
require Rails.root.join("mcp/provenance_mcp")
ProvenanceMcp.tools

# The audit log through MCP (3.1 step 2): the operator's client asks who did what and why. A read tool's call leaves
# the test's transaction read-only: each example writes before its first call.
RSpec.describe "Querying the audit log through MCP" do
  let!(:company) { create(:company, :resolved, name: "Acme", domain: "acme.example") }
  let!(:role) { create(:posting, company: company, role_title: "Sales Engineer") }

  def call(**arguments) = ProvenanceMcp::Tools::QueryAuditLog.call(**arguments, server_context: nil)

  def said(response) = response.content.sole[:text]

  # A check that closed the role, under its credential; the operator's rename; a write refused.
  def history
    credential = as_agent("agent:verifier") do |run|
      role.update!(verification_state: "not_found", last_checked_at: Time.current, roles_listed_count: 12)
      AuditEvent.record_write!(role, actor: "agent:verifier", reasoning: "Not among the 12 roles listed.")
      run
    end
    company.update!(name: "Acme Inc")
    AuditEvent.record_write!(company, actor: AuditEvent::OPERATOR, reasoning: "Its legal name.")
    create(:audit_event, actor: "agent:suggester", action: "denied", target: role, changes_made: { "tracking" => %w[suggested tracked] },
                         reasoning: "Denied: may not update a posting (tracking).")
    credential
  end

  it "gives the count by who, then each event: who, what was done to which record and under which credential, and why" do
    credential = history

    text = said(call)

    expect(text).to start_with("3 events, newest first: 1 to 3 here. Times are UTC.\nBy: suggester 1, verifier 1, operator 1.\n<record>\n")
    expect(text).to include(%(agent:verifier changed role "Sales Engineer" at Acme Inc [#{role.id}] (credential: spec [#{credential.id}])),
                            "verification_state: pending → not_found", "last_checked_at: — → ",
                            "  Why: Not among the 12 roles listed.",
                            "operator changed company Acme Inc [#{company.id}]\n  Changed: name: Acme → Acme Inc\n  Why: Its legal name.",
                            %(agent:suggester refused role "Sales Engineer" at Acme Inc [#{role.id}]\n  Changed: tracking: suggested → tracked))
    expect(text).to end_with("</record>")
  end

  it "narrows by who, kind, action, attribute, days, one record or a credential, and pages" do
    credential = history

    expect(said(call(who: "verifier"))).to start_with("1 event (who agent:verifier), newest first").and include("Not among the 12")
    expect(said(call(kind: "company", action: "update"))).to include("Its legal name.").and(not_include("Not among"))
    expect(said(call(action: "denied"))).to include("refused").and(not_include("Its legal name."))
    expect(said(call(attribute: "name", from: Date.current.to_s, to: Date.current.to_s))).to include("Its legal name.").and(not_include("Not among"))
    expect(said(call(record: role.id))).to start_with("2 events (record #{role.id})")
    expect(said(call(credential: credential.id))).to include("Not among the 12").and(not_include("refused"))
    expect(said(call(limit: 1, offset: 1))).to start_with("3 events, newest first: 2 to 2 here; offset: 2 for older ones.").and include("Its legal name.")
    expect(said(call(who: "verifier"))).not_to include("By:")
  end

  # Found on the real record: 25 events of up to 2,000 characters each ran past what a tool may say, so the answer was
  # cut mid-event while saying it held all 25.
  it "holds as many whole events as fit what a tool may say, and says where the rest start" do
    history
    two = AuditLog.new.events.first(2).sum { |event| AuditLog.describe(event).join("\n").size + 2 }
    stub_const("ProvenanceMcp::Tools::QueryAuditLog::BUDGET", two)

    text = said(call)

    expect(text).to start_with("3 events, newest first: 1 to 2 here; offset: 2 for older ones.").and end_with("</record>")
    expect(text.scan(" UTC  ").size).to eq(2)
  end

  it "refuses a filter it can't apply, saying why, and says when nothing matches" do
    history

    unknown = call(who: "someone")
    expect(unknown.error?).to be(true)
    expect(said(unknown)).to start_with('Unknown actor "someone": operator, agents, or one of')
    expect(said(call(record: "acme"))).to eq('Record is an id (a uuid), not "acme"')
    expect(said(call(from: Date.tomorrow.to_s))).to eq("No event matches (from #{Date.tomorrow}).")
  end

  it "keeps its lists in step with the app's" do
    schema = ProvenanceMcp::Tools::QueryAuditLog.to_h.dig(:inputSchema, :properties)

    expect(schema.dig(:action, :enum)).to eq(AuditLog::ACTIONS.keys)
    expect(schema.dig(:who, :description)).to include(*(Authority::AGENTS.keys + Authority::SYSTEM.keys).map { |actor| actor.split(":").last })
    expect(schema.dig(:kind, :description)).to include(*AuditLog::KIND_NAMES.values, "review_item", "fit_score", "search_profile")
    expect(ProvenanceMcp::INSTRUCTIONS).to include("use query_audit_log")
  end
end
