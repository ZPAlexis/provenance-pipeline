module AuditHelper
  # Past this many lines, an event's changes fold, the first few showing.
  SHOWN_CHANGES = 4
  LONG_VALUE = 200

  # The log's filters as the page's parameters, changed by `changes` (nil drops one).
  def audit_params(log, **changes)
    log.to_params.except(:action).merge(act: log.action).merge(changes).compact
  end

  # Who wrote the events under the other filters: everyone, the operator, every agent, then each actor, with counts.
  def audit_who_chips(log, by_who)
    counts = by_who.to_h
    counts[log.who] ||= 0 if log.who && log.who != "agents"
    agents = counts.select { |who, _| who.start_with?("agent:") }.values.sum
    [ [ nil, "Everyone", counts.values.sum ], ([ "operator", "Operator", counts.delete("operator") ] if counts.key?("operator")),
      ([ "agents", "Every agent", agents ] if agents.positive? || log.who == "agents"),
      *counts.map { |who, count| [ who, actor_label(who), count ] } ].compact
  end

  # What an event is about, linked to its page: a role with its company (titles repeat from one company to the
  # next), a review item with its kind and company. Below it, "its events" narrows the log to that record.
  def audit_subject(event, log)
    context = case (target = event.target)
    when Posting then "at #{target.company.name}"
    when ReviewItem then "#{ReviewGuidance.label(target.kind)} at #{target.company.name}"
    end
    narrow = link_to("its events", audit_path(record: event.target_id), title: "Every event about this record") if event.target_id && event.target_id != log.record
    return event_subject(event) unless context || narrow

    safe_join([ event_subject(event), tag.div(safe_join([ context, narrow ].compact, " · "), class: "muted small") ])
  end

  def audit_action_badge(event)
    tag.span(AuditLog::ACTIONS.fetch(event.action, event.action), class: [ "badge", ("gone" if event.action == "denied") ])
  end

  # Each attribute an event set, a line each: what it was and what it became. A create shows what it set and a
  # delete what the record held; a JSONB field shows each key that changed. What the log keeps as a hash (a
  # contact's details, a draft's text) is shown as that hash. An id links to the log narrowed to that record.
  def audit_changes(event)
    lines = AuditLog.changes(event).map do |change|
      shown = change.pair ? safe_join([ audit_value(change.attribute, change.before), " → ", audit_value(change.attribute, change.after) ]) :
                            audit_value(change.attribute, change.after)
      tag.li(safe_join([ tag.code(change.attribute), " ", shown ]))
    end
    return tag.span("—", class: "muted") if lines.empty?

    shown, more = lines.size > SHOWN_CHANGES + 1 ? [ lines.first(SHOWN_CHANGES), lines.drop(SHOWN_CHANGES) ] : [ lines, [] ]
    safe_join([ tag.ul(safe_join(shown), class: "changes"),
                (tag.details(safe_join([ tag.summary("#{more.size} more"), tag.ul(safe_join(more), class: "changes") ])) if more.any?) ])
  end

  private

  def audit_value(attribute, value)
    case value
    when nil then tag.span("—", class: "muted")
    when AuditLog::UUID
      attribute.end_with?("_id") ? link_to(value.first(8), audit_path(record: value), title: "Its events in the audit log") : value
    when %r{\Ahttps?://} then outside_link(value)
    when String then audit_text(value)
    when Array then audit_text(value.map(&:to_s).join(", "))
    when Hash then audit_text(value.to_json)
    else value.to_s
    end
  end

  def audit_text(text)
    text.length > LONG_VALUE ? tag.span(text.truncate(LONG_VALUE), title: text) : text
  end
end
