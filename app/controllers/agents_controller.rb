# Who may write what (1.3): each agent and its scopes, as the code defines them,
# the credentials its runs were issued, and every write refused.
class AgentsController < ApplicationController
  RECENT = 25
  WINDOW = 30.days

  def index
    @actor = params[:actor] if Authority::AGENTS.key?(params[:actor])
    actors = Authority::AGENTS.keys + Authority::SYSTEM.keys
    recent = AuditEvent.where(actor: actors, occurred_at: WINDOW.ago..)
    @writes = recent.where.not(action: "denied").group(:actor).count
    @refusals = recent.denied.group(:actor).count
    @last_issued = AgentCredential.group(:actor).maximum(:created_at)
    @issued = AgentCredential.group(:actor).count

    credentials = AgentCredential.newest_first
    @credentials = (@actor ? credentials.where(actor: @actor) : credentials).limit(RECENT).to_a
    ids = @credentials.map(&:id)
    @wrote = AuditEvent.where(credential_id: ids).where.not(action: "denied").group(:credential_id).count
    @refused = AuditEvent.denied.where(credential_id: ids).group(:credential_id).count
    @denied = AuditEvent.denied.order(occurred_at: :desc).limit(RECENT).preload(:target, :credential)
    # How the assistant's recommendations on the review queue came out (2g): agreement, the ground for any autonomy.
    @recommendations = ReviewRecommendations.totals
  end
end
