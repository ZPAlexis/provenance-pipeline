require "rails_helper"

# The commands that read the record and answer for it (1.3, 3.1, 3.3), and the backup by hand, as the operator runs them.
RSpec.describe "agents:, audit:, analytics: and db: commands" do
  let!(:company) { create(:company, :resolved, name: "Acme", domain: "acme.example") }
  let!(:role) { create(:posting, company: company, role_title: "Sales Engineer", tracking: "tracked") }

  it "lists the credentials runs held, with what each wrote, and revokes one as the operator" do
    as_agent("agent:verifier", scopes: %w[postings:verify]) do
      role.update!(verification_state: "not_found", last_checked_at: Time.current, roles_listed_count: 12)
      AuditEvent.record_write!(role, actor: "agent:verifier", reasoning: "Not among the 12 roles listed.")
    end
    credential, = AgentCredential.issue!(actor: "agent:suggester", scopes: %w[postings:suggest], purpose: "verifier:suggest",
                                         ttl: 1.hour, issued_by: AuditEvent::OPERATOR)

    listed = run_task("agents:credentials").out
    expect(listed).to include("revoked  agent:verifier", "wrote   1", "active   agent:suggester", "Refused writes: 0")
    expect(run_task("agents:credentials", ACTOR: "agent:nobody").aborted).to start_with("ACTOR is one of:")

    expect(run_task("agents:revoke", credential.id, NOTE: "Started by mistake.").out).to include("Revoked agent:suggester's credential")
    expect(credential.reload.status).to eq("revoked")
    expect(run_task("agents:revoke", credential.id).aborted).to eq("It is already revoked.")
  end

  it "reads the audit log narrowed as on its page, and the analytics by section" do
    role.update!(tracking: "dismissed")
    AuditEvent.record_write!(role, actor: AuditEvent::OPERATOR, reasoning: "Dismissed by hand.")

    expect(run_task("audit:list", WHO: "operator").out).to include("1 event", "newest first", "Dismissed by hand.")
    expect(run_task("audit:list", WHO: "suggester").aborted).to start_with("No event matches")
    expect(run_task("analytics:report", SECTION: "pipeline").out).to start_with("Pipeline (every application): none yet.")
    expect(run_task("analytics:report", SECTION: "everything").aborted).to start_with("SECTION is one of:")
    expect(run_task("analytics:report", SINCE: "last week").aborted).to eq('SINCE is a day as YYYY-MM-DD, not "last week".')
  end

  it "backs up by hand" do
    expect(run_task("db:backup").out).to eq("Backed up to #{Rails.root.join('tmp/backups/stand-in.dump')}\n")
  end
end
