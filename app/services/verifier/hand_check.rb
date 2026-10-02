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
