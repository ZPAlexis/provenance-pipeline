require "rails_helper"

RSpec.describe AuditEvent do
  describe "validations" do
    it "requires an actor" do
      expect(build(:audit_event, actor: nil)).not_to be_valid
    end

    it "requires an action" do
      expect(build(:audit_event, action: nil)).not_to be_valid
    end

    it "does not require a target" do
      expect(build(:audit_event, :without_target)).to be_valid
    end
  end

  describe "occurred_at" do
    it "defaults to now on create" do
      freeze_time do
        expect(create(:audit_event).occurred_at).to eq(Time.current)
      end
    end

    it "keeps an explicitly given time" do
      at = 3.days.ago.change(usec: 0)
      expect(create(:audit_event, occurred_at: at).occurred_at).to eq(at)
    end
  end

  describe ".record!" do
    let(:posting) { create(:posting) }

    it "persists who, what, why, and on which record" do
      freeze_time do
        event = described_class.record!(
          actor: "agent:verifier",
          action: "verify",
          target: posting,
          changes_made: { verification_state: %w[pending verified_live] },
          model_version: "test-model-1",
          reasoning: "Role listed on the careers page."
        )

        expect(event.reload).to have_attributes(
          actor: "agent:verifier",
          action: "verify",
          target: posting,
          changes_made: { "verification_state" => %w[pending verified_live] },
          model_version: "test-model-1",
          reasoning: "Role listed on the careers page.",
          occurred_at: Time.current
        )
      end
    end

    it "defaults changes_made to an empty hash" do
      expect(described_class.record!(actor: "agent:test", action: "noop").changes_made).to eq({})
    end

    it "raises rather than silently skipping an invalid event" do
      expect { described_class.record!(actor: nil, action: "create") }
        .to raise_error(ActiveRecord::RecordInvalid)
    end
  end

  describe "scopes" do
    let!(:agent_event) { create(:audit_event, actor: "agent:clay_importer") }
    let!(:human_event) { create(:audit_event, :by_human) }

    it "filters by exact actor" do
      expect(described_class.by_actor("agent:clay_importer")).to contain_exactly(agent_event)
    end

    it "separates agent writes from human writes" do
      expect(described_class.by_agents).to contain_exactly(agent_event)
    end

    it "limits to the last 24 hours by default" do
      old_event = create(:audit_event, occurred_at: 2.days.ago)

      expect(described_class.recent).to include(agent_event, human_event)
      expect(described_class.recent).not_to include(old_event)
    end

    it "accepts a custom window" do
      old_event = create(:audit_event, occurred_at: 2.days.ago)
      expect(described_class.recent(3.days.ago)).to include(old_event)
    end
  end
end
