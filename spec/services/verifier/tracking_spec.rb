require "rails_helper"

RSpec.describe Verifier::Tracking do
  let(:posting) { create(:posting, role_title: "RevOps Engineer") }

  it "dismisses a role for good, audited as the operator with why" do
    described_class.dismiss!(posting, note: "Not a fit: relocation required.")

    expect(posting.reload.tracking).to eq("dismissed")
    event = posting.audit_events.sole
    expect(event).to have_attributes(actor: "human:operator")
    expect(event.changes_made["tracking"]).to eq([ "tracked", "dismissed" ])
    expect(event.reasoning).to eq("Dismissed by hand: never checked or suggested again. Not a fit: relocation required.")
  end

  it "tracks a suggested or dismissed role again, audited as the operator" do
    posting.update!(tracking: "suggested")

    described_class.track!(posting, note: "Exactly the role I want.")

    expect(posting.reload.tracking).to eq("tracked")
    expect(posting.audit_events.sole.reasoning).to eq("Tracked by hand. Exactly the role I want.")
  end

  it "needs a reason, and writes nothing for a role already in that state" do
    expect { described_class.dismiss!(posting, note: " ") }.to raise_error(ArgumentError, /NOTE=/)
    expect { described_class.track!(posting, note: "Again.") }.to raise_error(ArgumentError, "already tracked")
    expect(posting.audit_events).to be_empty
  end
end
