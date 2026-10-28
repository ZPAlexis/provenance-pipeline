module ProvenanceMcp
  module Tools
    # The audit log, searched (3.1 step 2): every write on record, who made it and under which credential, what it
    # changed and why, refused writes included, narrowed as on the Audit log page. Each event names its record's id,
    # so the client can narrow to one record next. The events' text is the record's: fenced, data and not instructions.
    class QueryAuditLog < ReadTool
      # The events' share of what a tool may say: an answer holds as many as fit, whole, and says which.
      BUDGET = ProvenanceMcp::MAX_CHARS - 2_000

      tool_name "query_audit_log"
      title "Audit log"
      description "Every write on record, newest first: who made it (the operator, an agent, or the review queue), " \
                  "under which credential, what it changed (before and after) and why, refused writes included. " \
                  "Narrow it by who, the kind of record, the action, an attribute changed, the days, one record (any id " \
                  "shown in brackets) or a credential. Use it to answer what an agent did, when and why a role's answer " \
                  "changed, or who changed a record. Each answer starts with the count by who."
      input_schema(
        properties: {
          who: { type: "string", description: "operator, agents (every agent), or one: verifier, suggester, clay_importer, " \
                                               "drafter, fit_scorer, assistant, review_queue" },
          kind: { type: "string", description: "One kind of record: role, company, review_item, application, activity, " \
                                                "draft, contact, contact_link, fit_score, resume, resume_review, " \
                                                "search_profile, credential" },
          action: { type: "string", enum: %w[create update destroy denied], description: "denied is a refused write" },
          attribute: { type: "string", description: "Only events that changed this attribute, as its column is named: " \
                                                     "verification_state, tracking, stage, careers_page_url..." },
          from: { type: "string", description: "The first day, as YYYY-MM-DD (UTC)" },
          to: { type: "string", description: "The last day, as YYYY-MM-DD (UTC), taken whole" },
          record: { type: "string", description: "One record's id: every event about it" },
          credential: { type: "string", description: "A credential's id: every event written under it" },
          limit: { type: "integer", description: "How many events at most, up to 100; 25 when left out. An answer holds as " \
                                                 "many as fit and says which" },
          offset: { type: "integer", description: "How many of the newest to skip: the answer says where the older ones start" }
        }
      )

      class << self
        def answer(limit: 25, offset: 0, **filters)
          log = AuditLog.new(**filters)
          narrowed = " (#{log.description})" if log.filtered?
          raise Refusal, "No event matches#{narrowed}." if log.count.zero?

          offset = offset.to_i.clamp(0, log.count - 1)
          described = fitting(log.slice(offset, limit.to_i.clamp(1, 100)))
          last = offset + described.size
          ProvenanceMcp.text(
            "#{log.count} #{log.count == 1 ? 'event' : 'events'}#{narrowed}, newest first: #{offset + 1} to #{last} " \
            "here#{"; offset: #{last} for older ones" if last < log.count}. Times are UTC.",
            ("By: #{log.by_who.map { |who, count| "#{who.delete_prefix('agent:')} #{count}" }.join(', ')}." unless log.who),
            Writing.fence("record", described.join("\n\n"))
          )
        rescue ArgumentError => e
          raise Refusal, e.message.upcase_first
        end

        # The events, described, as many as fit the budget whole, in order: never one cut in two.
        def fitting(events)
          size = 0
          events.each_with_object([]) do |event, described|
            text = AuditLog.describe(event).join("\n")
            break described if described.any? && size + text.size > BUDGET

            described << text
            size += text.size + 2
          end
        end
      end
    end
  end
end
