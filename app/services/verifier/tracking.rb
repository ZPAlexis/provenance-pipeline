module Verifier
  # The operator's watch list: which roles they track, and since 4a which companies. The agent may suggest a
  # role; only the operator tracks or dismisses one, audited as theirs with why.
  # A dismissed role is never checked or suggested again, until the operator
  # tracks it again by hand. An archived company ("dismissed", stored as a role's is) is never watched: not
  # checked, not suggested from, nothing raised to review; its roles in play are archived with it.
  module Tracking
    # How a role archived with its company is told apart from one archived on its own: tracking the company again
    # brings back only these, each to the state it had.
    WITH_COMPANY = "Archived with its company:".freeze

    module_function

    def track!(posting, note:, actor: AuditEvent::OPERATOR)
      decide!(posting, "tracked", "Tracked by hand.", note, actor)
    end

    def dismiss!(posting, note:, actor: AuditEvent::OPERATOR)
      decide!(posting, "dismissed", "Dismissed by hand: never checked or suggested again.", note, actor)
    end

    # Archives a company and its roles in play (tracked or suggested), each audited with the operator's note. A
    # company with an application still open is the operator's to close first.
    def dismiss_company!(company, note:, actor: AuditEvent::OPERATOR)
      refuse_company!(company, "dismissed", note)
      if (open = company.applications.open.includes(:posting).first)
        raise ArgumentError, "#{company.name} has an open application (#{open.posting.role_title}): close or withdraw it first"
      end

      ApplicationRecord.transaction do
        company.update!(tracking: "dismissed")
        AuditEvent.record_write!(company, actor: actor,
                                          reasoning: "Archived by hand: never checked, suggested from or reviewed again. #{note}")
        roles = company.postings.not_dismissed.to_a
        roles.each do |posting|
          posting.update!(tracking: "dismissed")
          AuditEvent.record_write!(posting, actor: actor, reasoning: "#{WITH_COMPANY} #{note}")
        end
        ReviewQueue.sync!(company, actor: actor)
        roles
      end
    end

    # Tracks an archived company again, and (unless asked not to) the roles archived with it, each as it was before.
    def track_company!(company, note:, with_roles: true, actor: AuditEvent::OPERATOR)
      refuse_company!(company, "tracked", note)

      ApplicationRecord.transaction do
        back = with_roles ? archived_with(company) : {}
        company.update!(tracking: "tracked")
        AuditEvent.record_write!(company, actor: actor, reasoning: "Tracked by hand. #{note}")
        back.each do |posting, was|
          posting.update!(tracking: was)
          AuditEvent.record_write!(posting, actor: actor, reasoning: "Back with its company: #{note}")
        end
        ReviewQueue.sync!(company, actor: actor)
        back.keys
      end
    end

    # The company's roles archived with it when it was last archived, each with the state it had then: a role
    # archived on its own, or with an earlier archiving the operator didn't undo, stays archived. Written in one
    # transaction with the company's own event, within a minute of it (WSL's clock steps back now and then).
    def archived_with(company)
      archived = company.audit_events.where("changes_made -> 'tracking' ->> 1 = 'dismissed'").maximum(:occurred_at) or return {}
      company.postings.where(tracking: "dismissed").each_with_object({}) do |posting, back|
        last = posting.audit_events.where("changes_made ? 'tracking'").order(occurred_at: :desc).first
        next unless last&.reasoning.to_s.start_with?(WITH_COMPANY) && last.occurred_at >= archived - 1.minute

        back[posting] = last.changes_made.dig("tracking", 0)
      end
    end

    def decide!(posting, tracking, mark, note, actor)
      raise ArgumentError, "say why: the note becomes the audit reasoning" if note.blank?
      raise ArgumentError, "already #{tracking}" if posting.tracking == tracking

      ApplicationRecord.transaction do
        posting.update!(tracking: tracking)
        AuditEvent.record_write!(posting, actor: actor, reasoning: "#{mark} #{note}")
        ReviewQueue.sync!(posting.company, actor: actor)
      end
    end

    def refuse_company!(company, tracking, note)
      raise ArgumentError, "say why: the note becomes the audit reasoning" if note.blank?
      raise ArgumentError, "#{company.name} is already #{tracking == 'tracked' ? 'tracked' : 'archived'}" if company.tracking == tracking
    end
    private_class_method :decide!, :refuse_company!
  end
end
