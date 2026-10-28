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

  # What an event is about; a role with its company, since titles repeat from one company to the next.
  def audit_subject(event)
    subject = event_subject(event)
    return subject unless event.target.is_a?(Posting)

    safe_join([ subject, tag.div("at #{event.target.company.name}", class: "muted small") ])
  end

  def audit_action_badge(event)
    tag.span(AuditLog::ACTIONS.fetch(event.action, event.action), class: [ "badge", ("gone" if event.action == "denied") ])
  end

  # Each attribute an event set, a line each: what it was and what it became. A create shows what it set and a
  # delete what the record held; a JSONB field shows each key that changed. What the log keeps as a hash (a
  # contact's details, a draft's text) is shown as that hash. An id links to the log narrowed to that record.
  def audit_changes(event)
    lines = event.changes_made.flat_map do |attribute, change|
      next [ audit_change(attribute, change, event) ] unless change.is_a?(Hash)

      change.map { |key, pair| audit_change("#{attribute}.#{key}", pair, event) }
    end
    return tag.span("—", class: "muted") if lines.empty?

    shown, more = lines.size > SHOWN_CHANGES + 1 ? [ lines.first(SHOWN_CHANGES), lines.drop(SHOWN_CHANGES) ] : [ lines, [] ]
    safe_join([ tag.ul(safe_join(shown), class: "changes"),
                (tag.details(safe_join([ tag.summary("#{more.size} more"), tag.ul(safe_join(more), class: "changes") ])) if more.any?) ])
  end

  private

  def audit_change(attribute, change, event)
    tag.li(safe_join([ tag.code(attribute), " ", audit_change_text(attribute, change, event) ]))
  end

  def audit_change_text(attribute, change, event)
    return audit_value(attribute, change) unless change.is_a?(Array) && change.size == 2

    before, after = change
    case event.action
    when "create" then audit_value(attribute, after)
    when "destroy" then audit_value(attribute, before)
    else safe_join([ audit_value(attribute, before), " → ", audit_value(attribute, after) ])
    end
  end

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
