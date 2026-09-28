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

  describe ".record_write!" do
    it "records a create as a snapshot of everything the write set, as [before, after] pairs" do
      posting = create(:posting, role_title: "GTM Engineer", location: nil, enrichment: { "hiring_evidence" => "Listed." })
      event = described_class.record_write!(posting, actor: "agent:test", reasoning: "Imported.")

      expect(event).to have_attributes(action: "create", target: posting, actor: "agent:test", reasoning: "Imported.")
      expect(event.changes_made).to include(
        "role_title" => [ nil, "GTM Engineer" ],
        "company_id" => [ nil, posting.company_id ],
        "verification_state" => [ nil, "pending" ],
        "enrichment" => { "hiring_evidence" => [ nil, "Listed." ] }
      )
    end

    it "leaves out ids, timestamps, and attributes the create left empty" do
      event = described_class.record_write!(create(:posting, location: nil), actor: "agent:test")

      expect(event.changes_made.keys).not_to include("id", "created_at", "updated_at", "location", "enrichment")
    end

    it "records an update with before and after for only what changed" do
      company = create(:company, careers_page_url: nil)
      company.update!(careers_page_url: "https://acme.example/careers")

      event = described_class.record_write!(company, actor: "agent:test")

      expect(event.action).to eq("update")
      expect(event.changes_made).to eq("careers_page_url" => [ nil, "https://acme.example/careers" ])
    end

    # An overwrite must never lose the previous value, and an event must never
    # carry the whole enrichment blob twice.
    it "diffs enrichment key by key" do
      company = create(:company, enrichment: { "Industry" => "Software", "Founded" => "2001" })
      company.update!(enrichment: { "Industry" => "Enterprise Software", "Founded" => "2001", "Stage" => "Series B" })

      event = described_class.record_write!(company, actor: "agent:test")

      expect(event.changes_made).to eq(
        "enrichment" => { "Industry" => [ "Software", "Enterprise Software" ], "Stage" => [ nil, "Series B" ] }
      )
    end

    it "records nothing when the save changed nothing" do
      company = create(:company)
      company.save!

      expect { described_class.record_write!(company, actor: "agent:test") }.not_to change(described_class, :count)
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
