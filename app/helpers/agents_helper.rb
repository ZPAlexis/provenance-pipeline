module AgentsHelper
  STATUS_TONES = { "active" => "live", "revoked" => "gone", "expired" => "" }.freeze
  # What an application's own records are called, before the role it is for.
  APPLICATION_PARTS = { "Activity" => "an activity on", "Draft" => "a draft for", "ResumeReview" => "a resume review for",
                        "ApplicationContact" => "a contact linked to" }.freeze

  def credential_badge(credential) = tag.span(credential.status, class: [ "badge", STATUS_TONES.fetch(credential.status) ])

  def scope_about(scope) = Authority::SCOPES.fetch(scope)[:about]

  def scope_chips(scopes) = safe_join(scopes.map { |scope| tag.code(scope, class: "scope", title: scope_about(scope)) }, " ")

  # What an audit event is about, linked to its page when it has one. A contact is named by its company only: the
  # log keeps a contact's details as hashes.
  def event_subject(event)
    case (target = event.target)
    when Posting then link_to(target.role_title, role_path(target))
    when Company then link_to(target.name, company_path(target))
    when ReviewItem then link_to("a review item", review_path)
    when AgentCredential then link_to(target.purpose, agent_credential_path(target))
    when SearchProfile then link_to("the search profile", profile_path)
    when Resume then link_to("the resume", profile_path)
    when Application then link_to("the application for #{target.posting.role_title}", application_path(target))
    when Activity, Draft, ResumeReview, ApplicationContact
      link_to("#{APPLICATION_PARTS.fetch(target.class.name)} #{target.application.posting.role_title}", application_path(target.application))
    when FitScore then link_to("the fit of #{target.posting.role_title}", role_path(target.posting, anchor: "fit"))
    when Contact then link_to("a contact at #{target.company.name}", company_path(target.company))
    else
      title = Array(event.changes_made["role_title"]).compact.first
      type = event.target_type&.underscore&.humanize
      type = "#{type} (deleted)" if type && target.nil?
      tag.span(title ? "#{title} (not on record)" : (type || "—"), class: "muted")
    end
  end

  # Refused writes lately, for the nav: any is worth a look.
  def agents_refused_recently = AuditEvent.denied.where(occurred_at: 7.days.ago..).count
end
