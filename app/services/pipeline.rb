# The operator's applications (Stage 2a): started from a role on record, moved
# between stages, and what happened along the way logged. Every write is audited
# as the operator's; no agent scope allows any of it (Authority), so an agent
# that tries is refused on the record. Stage dates are the operator's own (when
# it happened, not when it was typed), kept in each change's audit event.
module Pipeline
  module_function

  # Starts an application for a role, tracking the role if it isn't already.
  def start!(posting, stage: "interested", on: Date.current, note: nil, actor: AuditEvent::OPERATOR)
    raise ArgumentError, "#{posting.role_title} already has an application" if posting.application
    stage = known!(stage)
    reached!(on)

    ApplicationRecord.transaction do
      Verifier::Tracking.track!(posting, note: "An application was started.", actor: actor) unless posting.tracking == "tracked"
      application = Application.create!(posting: posting, company: posting.company, stage: stage, stage_changed_on: on)
      AuditEvent.record_write!(application, actor: actor,
                                            reasoning: [ "Started at #{Application.stage_label(stage)}.", note.presence ].compact.join(" "))
      application
    end
  end

  # Moves an application to a stage, on the date it happened.
  def move!(application, stage, on: Date.current, note: nil, actor: AuditEvent::OPERATOR)
    stage = known!(stage)
    reached!(on)
    raise ArgumentError, "it is already at #{Application.stage_label(stage)} since #{on}" if
      application.stage == stage && application.stage_changed_on == on

    ApplicationRecord.transaction do
      application.update!(stage: stage, stage_changed_on: on)
      AuditEvent.record_write!(application, actor: actor,
                                            reasoning: [ "Moved to #{Application.stage_label(stage)} by hand.", note.presence ].compact.join(" "))
    end
    application
  end

  # Something that happened along the way, on the date it happened.
  def log!(application, kind:, summary:, on: Date.current, actor: AuditEvent::OPERATOR)
    ApplicationRecord.transaction do
      activity = application.activities.create!(kind: kind, summary: summary.to_s.strip, occurred_on: on, logged_by: actor)
      AuditEvent.record_write!(activity, actor: actor, reasoning: "Logged by hand.")
      activity
    end
  end

  # Its notes and pay expectation, as the operator keeps them.
  def note!(application, notes:, comp_expectation:, actor: AuditEvent::OPERATOR)
    ApplicationRecord.transaction do
      application.update!(notes: notes.to_s.strip.presence, comp_expectation: comp_expectation.to_s.strip.presence)
      AuditEvent.record_write!(application, actor: actor, reasoning: "Notes kept by hand.")
    end
    application
  end

  def known!(stage)
    stage = stage.to_s
    return stage if Application::STAGES.include?(stage)

    raise ArgumentError, "unknown stage #{stage.inspect}: one of #{Application::STAGES.join(', ')}"
  end

  # A stage is reached on a day that has come; an activity may be booked ahead (an interview next week).
  def reached!(on)
    raise ArgumentError, "a stage is reached on a day that has come: #{on} is still ahead" if on > Date.current
  end
  private_class_method :known!, :reached!
end
