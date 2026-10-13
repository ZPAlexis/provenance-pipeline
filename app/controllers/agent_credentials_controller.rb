# One credential: what its run was issued, everything it wrote, and anything
# refused. Revoking it by hand stops its run at its next write.
class AgentCredentialsController < ApplicationController
  def show
    @credential = AgentCredential.find(params[:id])
    events = @credential.audit_events.order(:occurred_at).preload(:target)
    @refused, @wrote = events.partition { |event| event.action == "denied" }
    @revocation = AuditEvent.find_by(target: @credential)
  end

  def revoke
    credential = AgentCredential.find(params[:id])
    credential.revoke_by!(AuditEvent::OPERATOR, note: params[:note])
    redirect_back_or_to agent_credential_path(credential), notice: "Revoked: its run's next write is refused.", status: :see_other
  rescue ArgumentError => e
    redirect_back_or_to agent_credential_path(credential), alert: "Not revoked: #{e.message}.", status: :see_other
  end
end
