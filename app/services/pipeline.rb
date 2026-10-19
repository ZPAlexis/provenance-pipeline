# The operator's applications (Stage 2a): started from a role on record, moved
# between stages, and what happened along the way logged. Every write is audited
# as the operator's; no agent scope allows any of it (Authority), so an agent
# that tries is refused on the record. Stage dates are the operator's own (when
# it happened, not when it was typed), kept in each change's audit event.
module Pipeline
  # One line of an application's timeline: a stage it reached, or an activity.
  Entry = Data.define(:on, :at, :stage, :from, :activity, :note, :actor)

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
      AuditEvent.record_write!(application, actor: actor, reasoning: "Notes saved by hand.")
    end
    application
  end

  # An activity corrected: its kind, date, or summary. Returns nil when nothing changed.
  def edit_activity!(activity, kind:, summary:, on:, actor: AuditEvent::OPERATOR)
    ApplicationRecord.transaction do
      activity.update!(kind: kind, summary: summary.to_s.strip, occurred_on: on)
      AuditEvent.record_write!(activity, actor: actor, reasoning: "Edited by hand.") && activity
    end
  end

  # An activity taken off the timeline; its audit record keeps all it said.
  def delete_activity!(activity, actor: AuditEvent::OPERATOR)
    ApplicationRecord.transaction do
      AuditEvent.record_destroy!(activity, actor: actor, reasoning: "Deleted by hand.")
      activity.destroy!
    end
  end

  # Its stage changes (from the audit log, with the dates the operator gave) and its activities, newest first.
  # A move on the same day as the stage before it records no date (only what changed is audited): it
  # carries the date before, so the history is walked in order.
  def timeline(application)
    on = nil
    moves = application.audit_events.where("changes_made ? 'stage'").order(:occurred_at).map do |event|
      dated = event.changes_made.dig("stage_changed_on", 1)
      on = Date.iso8601(dated.to_s) if dated
      Entry.new(on: on || event.occurred_at.to_date, at: event.occurred_at, stage: event.changes_made.dig("stage", 1),
                from: event.changes_made.dig("stage", 0), activity: nil, note: event.reasoning, actor: event.actor)
    end
    activities = application.activities.map do |activity|
      Entry.new(on: activity.occurred_on, at: activity.created_at, stage: nil, from: nil, activity: activity,
                note: activity.summary, actor: activity.logged_by)
    end
    (moves + activities).sort_by { |entry| [ entry.on, entry.at ] }.reverse
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
