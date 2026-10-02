module Verifier
  # A check the operator made at the source: a verdict like the verifier's, with
  # the exact time it was made, audited as theirs with what they saw. Labels go
  # stale and imported research can be wrong; a human looking at the employer's
  # own page is the authority the system defers to.
  module HandCheck
    MARK = "Checked by hand at the source.".freeze

    module_function

    def record!(posting, verdict:, note:, roles: nil, work_mode: nil, actor: AuditEvent::OPERATOR, at: Time.current)
      raise ArgumentError, "VERDICT is one of #{Posting::VERDICTS.join(', ')}" unless Posting::VERDICTS.include?(verdict)
      raise ArgumentError, "say what you saw in NOTE=\"...\": it becomes the audit reasoning" if note.blank?

      ApplicationRecord.transaction do
        posting.update!(verification_state: verdict, last_checked_at: at, roles_listed_count: roles, work_mode: work_mode)
        AuditEvent.record_write!(posting, actor: actor, reasoning: "#{MARK} #{note}")
      end
    end

    UNDONE = %w[verification_state last_checked_at roles_listed_count work_mode].freeze

    # Restores what the verifier's latest verdict replaced, for a verdict the
    # operator judges was reached on bad evidence. Audited as theirs, with why.
    def undo_verdict!(posting, reasoning:, actor: AuditEvent::OPERATOR)
      raise ArgumentError, "say why in REASON=\"...\": it becomes the audit reasoning" if reasoning.blank?

      event = posting.audit_events.where(actor: Ingest::ACTOR).where("changes_made ? 'verification_state'")
                     .order(:occurred_at).last or raise ArgumentError, "no verdict by the verifier to undo"
      state = event.changes_made["verification_state"]
      ApplicationRecord.transaction do
        posting.update!(event.changes_made.slice(*UNDONE).transform_values(&:first))
        AuditEvent.record_write!(
          posting, actor: actor,
          reasoning: "Undid the verifier's verdict of #{event.occurred_at.utc.to_date} (#{state.join(' -> ')}). #{reasoning}"
        )
      end
    end

    # The verdict the operator's latest hand check left, read from the posting's
    # history: what verification_state was once that check was recorded.
    def latest_verdict(posting)
      state = nil
      posting.audit_events.order(:occurred_at).each_with_object([]) do |event, found|
        state = event.changes_made["verification_state"].last if event.changes_made["verification_state"]
        found << state if event.actor == AuditEvent::OPERATOR && event.reasoning.to_s.start_with?(MARK)
      end.last
    end
  end
end
