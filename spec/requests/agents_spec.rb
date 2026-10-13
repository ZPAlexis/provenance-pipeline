require "rails_helper"

RSpec.describe "Agents", type: :request do
  let!(:company) { create(:company, :resolved, name: "Acme", domain: "acme.example") }
  let!(:role) { create(:posting, company: company, role_title: "Sales Engineer") }

  # A check now as it runs: a verdict written under its credential, and a write it was refused.
  def check_run
    as_agent("agent:verifier", scopes: %w[postings:verify evidence:write]) do |credential|
      role.update!(verification_state: "not_found", last_checked_at: Time.current, roles_listed_count: 12)
      AuditEvent.record_write!(role, actor: "agent:verifier", reasoning: "Not among the 12 roles listed.")
      begin
        role.update!(tracking: "dismissed")
      rescue Authority::Denied
        nil
      end
      credential
    end
  end

  it "shows each agent's scopes from the code, the credentials its runs held, and the writes refused" do
    credential = check_run

    get agents_path

    expect(response).to have_http_status(:success)
    expect(response.body).to include("Verifier", "postings:verify", "A role&#39;s verdict", "Suggester", "postings:suggest",
                                     "Review queue", "review:keep", "Yours alone", "Track or dismiss a role")
    expect(response.body).to include(agent_credential_path(credential), "revoked", "Agents (1 refused)")
    expect(response.body).to include("may not update a posting (tracking) with postings:verify, evidence:write")

    get agents_path(actor: "agent:suggester")
    expect(response.body).to include("No credential issued yet to the suggester")
  end

  it "shows one credential: its scopes, what it wrote, and what it was refused" do
    credential = check_run

    get agent_credential_path(credential)

    expect(response.body).to include("Sales Engineer", "Not among the 12 roles listed.", "What it was refused",
                                     "when its run ended", "never stored")
    expect(response.body).not_to include("Revoke it")
  end

  it "revokes a credential by hand, audited as the operator, and refuses its run's next write" do
    credential, token = AgentCredential.issue!(actor: "agent:verifier", scopes: %w[postings:verify], purpose: "verifier:verify",
                                               ttl: 1.hour, issued_by: "human:operator")
    get agent_credential_path(credential)
    expect(response.body).to include("Revoke it")

    patch revoke_agent_credential_path(credential), params: { note: "Started by mistake." }

    expect(flash[:notice]).to start_with("Revoked")
    expect(AuditEvent.find_by!(target: credential)).to have_attributes(actor: "human:operator",
                                                                      reasoning: /Revoked by hand.*Started by mistake\./)
    expect { Authority.presenting(token) { nil } }.to raise_error(Authority::Denied, /revoked/)

    patch revoke_agent_credential_path(credential)
    expect(flash[:alert]).to eq("Not revoked: it is already revoked.")
  end

  it "links each agent write in a role's history to the credential behind it" do
    credential = check_run

    get role_path(role)

    expect(response.body).to include(agent_credential_path(credential), "Refused")
  end
end
