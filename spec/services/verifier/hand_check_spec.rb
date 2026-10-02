require "rails_helper"

RSpec.describe Verifier::HandCheck do
  let(:posting) { create(:posting, :verified_live, enrichment: { "raw_verification" => "verified_live" }) }

  it "records the operator's check as the posting's verdict, audited as theirs with what they saw" do
    described_class.record!(posting, verdict: "not_found", note: "The careers page lists 7 roles; this is not one.",
                                     roles: 7, at: Time.utc(2026, 10, 1, 15))

    expect(posting.reload).to have_attributes(verification_state: "not_found", roles_listed_count: 7, work_mode: nil,
                                              last_checked_at: Time.utc(2026, 10, 1, 15))
    event = posting.audit_events.sole
    expect(event).to have_attributes(actor: AuditEvent::OPERATOR, action: "update")
    expect(event.reasoning).to eq("Checked by hand at the source. The careers page lists 7 roles; this is not one.")
  end

  it "refuses an unknown verdict or no note, writing nothing" do
    expect { described_class.record!(posting, verdict: "closed", note: "gone") }.to raise_error(ArgumentError, /VERDICT/)
    expect { described_class.record!(posting, verdict: "not_found", note: " ") }.to raise_error(ArgumentError, /NOTE/)
    expect(posting.reload.audit_events).to be_empty
  end

  describe ".latest_verdict" do
    it "reads the verdict the latest hand check left, even when it confirmed the one before" do
      AuditEvent.record_write!(posting, actor: "agent:clay_importer")
      described_class.record!(posting, verdict: "not_found", note: "Not on the page.")
      described_class.record!(posting, verdict: "not_found", note: "Still not there.", at: 1.hour.from_now)

      expect(described_class.latest_verdict(posting)).to eq("not_found")
    end

    it "is nil when nobody has checked by hand" do
      expect(described_class.latest_verdict(posting)).to be_nil
    end
  end

  describe ".undo_verdict!" do
    it "restores what the verifier's latest verdict replaced, audited as the operator with why" do
      pending_posting = create(:posting, verification_state: "pending")
      pending_posting.update!(verification_state: "not_found", last_checked_at: Time.utc(2026, 10, 2, 14), roles_listed_count: 0)
      AuditEvent.record_write!(pending_posting, actor: Verifier::Ingest::ACTOR, reasoning: "Run x.")

      described_class.undo_verdict!(pending_posting, reasoning: "The portal was down for maintenance: no roles were read.")

      expect(pending_posting.reload).to have_attributes(verification_state: "pending", last_checked_at: nil, roles_listed_count: nil)
      event = pending_posting.audit_events.order(:occurred_at).last
      expect(event.actor).to eq(AuditEvent::OPERATOR)
      expect(event.reasoning).to include("Undid the verifier's verdict of #{Time.current.utc.to_date} (pending -> not_found).",
                                         "down for maintenance")
    end

    it "refuses without a reason, or with no verifier verdict to undo" do
      expect { described_class.undo_verdict!(posting, reasoning: "Wrong.") }.to raise_error(ArgumentError, /no verdict/)
      expect { described_class.undo_verdict!(posting, reasoning: " ") }.to raise_error(ArgumentError, /REASON/)
    end
  end
end
