module Verifier
  # The operator's watch list: which roles they track. The agent may suggest a
  # role; only the operator tracks or dismisses one, audited as theirs with why.
  # A dismissed role is never checked or suggested again, until the operator
  # tracks it again by hand.
  module Tracking
    module_function

    def track!(posting, note:, actor: AuditEvent::OPERATOR)
      decide!(posting, "tracked", "Tracked by hand.", note, actor)
    end

    def dismiss!(posting, note:, actor: AuditEvent::OPERATOR)
      decide!(posting, "dismissed", "Dismissed by hand: never checked or suggested again.", note, actor)
    end

    def decide!(posting, tracking, mark, note, actor)
      raise ArgumentError, "say why in NOTE=\"...\": it becomes the audit reasoning" if note.blank?
      raise ArgumentError, "already #{tracking}" if posting.tracking == tracking

      ApplicationRecord.transaction do
        posting.update!(tracking: tracking)
        AuditEvent.record_write!(posting, actor: actor, reasoning: "#{mark} #{note}")
      end
    end
    private_class_method :decide!
  end
end
