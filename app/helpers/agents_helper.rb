module AgentsHelper
  STATUS_TONES = { "active" => "live", "revoked" => "gone", "expired" => "" }.freeze

  def credential_badge(credential) = tag.span(credential.status, class: [ "badge", STATUS_TONES.fetch(credential.status) ])

  def scope_about(scope) = Authority::SCOPES.fetch(scope)[:about]

  def scope_chips(scopes) = safe_join(scopes.map { |scope| tag.code(scope, class: "scope", title: scope_about(scope)) }, " ")

  # What an audit event is about, linked to its page when it has one.
  def event_subject(event)
    case (target = event.target)
    when Posting then link_to(target.role_title, role_path(target))
    when Company then link_to(target.name, company_path(target))
    when ReviewItem then link_to("a review item", review_path)
    when AgentCredential then link_to(target.purpose, agent_credential_path(target))
    when SearchProfile then link_to("the search profile", profile_path)
    else
      title = Array(event.changes_made["role_title"]).compact.first
      tag.span(title ? "#{title} (not on record)" : (event.target_type&.underscore&.humanize || "—"), class: "muted")
    end
  end

  # Refused writes lately, for the nav: any is worth a look.
  def agents_refused_recently = AuditEvent.denied.where(occurred_at: 7.days.ago..).count
end
