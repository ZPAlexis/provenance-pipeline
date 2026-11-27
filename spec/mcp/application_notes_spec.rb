require "rails_helper"
require Rails.root.join("mcp/provenance_mcp")
ProvenanceMcp.tools

# An application's notes and pay expectation through MCP (4f step 1): on the operator's word, as agent:assistant, under
# a credential for each call holding applications:note. A note goes after what is there, dated, never in its place;
# the pay expectation is replaced when they say. Save tools write, so these examples may write after a call.
RSpec.describe "An application's notes, through MCP" do
  let!(:company) { create(:company, :resolved, name: "Acme", domain: "acme.example") }
  let!(:application) do
    create(:application, posting: create(:posting, company: company, role_title: "Sales Engineer"), stage: "applied",
                         notes: "Remote-first team.", comp_expectation: "20k a month")
  end

  def call(tool, **arguments) = ProvenanceMcp::Tools.const_get(tool).call(**arguments, server_context: nil)

  def said(response) = response.content.sole[:text]

  it "adds a dated note after the operator's, as the assistant, with their reason on the record" do
    travel_to Time.utc(2026, 11, 27, 15) do
      response = call(:SaveApplicationNotes, application: "acme sales", note: "Ask about the team's on-call rotation.",
                                             reason: "The operator asked me to keep this question for the interview.")

      expect(application.reload.notes).to eq("Remote-first team.\n\nAdded by your AI assistant, 2026-11-27: Ask about the team's on-call rotation.")
      expect(application.comp_expectation).to eq("20k a month")
      expect(said(response)).to include("<record>\nAcme / Sales Engineer\n</record>", "Added to its notes, dated 2026-11-27, after what was there.",
                                        "Application id #{application.id}.")
      expect(said(response)).not_to include("pay expectation is set")
      expect(AgentCredential.sole).to have_attributes(actor: "agent:assistant", scopes: %w[applications:note],
                                                      purpose: "mcp: save_application_notes", status: "revoked")
      event = AuditEvent.find_by!(target: application, action: "update")
      expect(event).to have_attributes(actor: "agent:assistant", credential_id: AgentCredential.sole.id,
                                       reasoning: "A note added on the operator's word. The operator asked me to keep this question for the interview.")
    end
  end

  it "replaces the pay expectation, naming the one it replaced, and starts the notes when there were none" do
    application.update_columns(notes: nil)

    response = call(:SaveApplicationNotes, application: application.id, pay_expectation: "25k a month", note: "Offer range shared.",
                                           reason: "The recruiter's call.")

    expect(application.reload).to have_attributes(comp_expectation: "25k a month")
    expect(application.notes).to match(/\AAdded by your AI assistant, \d{4}-\d{2}-\d{2}: Offer range shared.\z/)
    expect(said(response)).to include("Its pay expectation is set; between markers, the new one and the one it replaced:",
                                      "<notes>\nNow: 25k a month\nWas: 20k a month\n</notes>")
    expect(AuditEvent.find_by!(target: application).reasoning)
      .to eq("A note added and its pay expectation set on the operator's word. The recruiter's call.")
  end

  it "says when nothing would change, and what it needs" do
    expect(said(call(:SaveApplicationNotes, application: application.id, pay_expectation: " 20k a month ", reason: "Same.")))
      .to end_with("Nothing changed: its pay expectation is that already.")
    expect(said(call(:SaveApplicationNotes, application: application.id, note: "x", reason: " ")))
      .to eq("Give the operator's reason: it goes on the record.")
    expect(said(call(:SaveApplicationNotes, application: application.id, reason: "Why not.")))
      .to eq("Give a note to add, or a pay expectation.")
    expect(AuditEvent.where(target: application)).to be_empty
  end

  # The rule itself, whatever a tool does: notes only grow under the scope, and nothing else of an application moves.
  it "refuses notes that don't begin with the ones before, a stage, and anything held under another scope, on the record" do
    as_agent("agent:assistant", scopes: %w[applications:note]) do
      expect { application.update!(notes: "Replaced.") }.to raise_error(Authority::Denied)
      expect { application.update!(stage: "interviewing") }.to raise_error(Authority::Denied)
      application.reload.update!(notes: "#{application.notes}\n\nMore.", comp_expectation: "30k a month")
    end
    as_agent("agent:assistant", scopes: %w[activities:write]) do
      expect { application.reload.update!(comp_expectation: "40k a month") }.to raise_error(Authority::Denied)
    end

    expect(application.reload).to have_attributes(notes: "Remote-first team.\n\nMore.", comp_expectation: "30k a month", stage: "applied")
    expect(AuditEvent.where(action: "denied", actor: "agent:assistant").count).to eq(3)
  end

  it "is a save tool, and the server tells the client to use it only on the operator's word" do
    expect(ProvenanceMcp::Tools::SaveApplicationNotes.ancestors).to include(ProvenanceMcp::SaveTool)
    expect(ProvenanceMcp::INSTRUCTIONS).to include("use save_application_notes, only on the person's",
                                                   "a note goes after theirs, dated as yours, never in its place")
    expect(Authority::AGENTS.fetch("agent:assistant")[:scopes]).to include("applications:note")
    expect(Authority::AGENTS.except("agent:assistant").values.flat_map { |agent| agent[:scopes] }).not_to include("applications:note")
  end
end
