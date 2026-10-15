require "rails_helper"

RSpec.describe Pipeline do
  let!(:company) { create(:company, :resolved, name: "Acme", domain: "acme.example") }
  let!(:role) { create(:posting, company: company, role_title: "Sales Engineer", tracking: "tracked") }

  describe ".start!" do
    it "starts one application for a role, at the stage and date given, audited as the operator's" do
      application = described_class.start!(role, stage: "applied", on: Date.new(2026, 10, 10), note: "Through its own site.")

      expect(application).to have_attributes(posting: role, company: company, stage: "applied",
                                             stage_changed_on: Date.new(2026, 10, 10), open?: true)
      expect(AuditEvent.find_by!(target: application)).to have_attributes(
        actor: "human:operator", action: "create", reasoning: "Started at Applied. Through its own site."
      )
      expect { described_class.start!(role) }.to raise_error(ArgumentError, /already has an application/)
    end

    it "tracks a role not yet tracked: a suggestion, or one dismissed" do
      suggested = create(:posting, company: company, role_title: "Solutions Engineer", tracking: "suggested")

      described_class.start!(suggested)

      expect(suggested.reload.tracking).to eq("tracked")
      expect(AuditEvent.where(target: suggested).pluck(:reasoning)).to include("Tracked by hand. An application was started.")
    end

    it "knows only its stages" do
      expect { described_class.start!(role, stage: "ghosted") }.to raise_error(ArgumentError, /unknown stage "ghosted"/)
    end
  end

  describe ".move!" do
    let(:application) { create(:application, posting: role, stage: "applied", stage_changed_on: Date.new(2026, 10, 1)) }

    it "moves it to a stage on the date it happened, the change and its date on the record" do
      described_class.move!(application, "interviewing", on: Date.new(2026, 10, 12), note: "First call booked.")

      expect(application.reload).to have_attributes(stage: "interviewing", stage_changed_on: Date.new(2026, 10, 12))
      event = AuditEvent.find_by!(target: application, action: "update")
      expect(event).to have_attributes(actor: "human:operator", reasoning: "Moved to Interviewing by hand. First call booked.")
      expect(event.changes_made).to eq("stage" => %w[applied interviewing], "stage_changed_on" => %w[2026-10-01 2026-10-12])
    end

    it "may go back a stage, as a correction, and closes it at an outcome" do
      described_class.move!(application, "interested", on: Date.new(2026, 10, 2))
      described_class.move!(application, "no_response", on: Date.new(2026, 10, 9))

      expect(application.reload).to have_attributes(stage: "no_response", open?: false)
      expect(Application.closed).to eq([ application ])
      expect { described_class.move!(application, "no_response", on: Date.new(2026, 10, 9)) }
        .to raise_error(ArgumentError, /already at No response/)
      expect { described_class.move!(application, "offer", on: Date.current + 1) }
        .to raise_error(ArgumentError, /a stage is reached on a day that has come/)
    end
  end

  it "logs what happened along the way, audited as the operator's" do
    application = create(:application, posting: role)

    activity = described_class.log!(application, kind: "interview", summary: " Panel with the sales team. ", on: Date.new(2026, 10, 14))

    expect(activity).to have_attributes(kind: "interview", summary: "Panel with the sales team.", logged_by: "human:operator",
                                        occurred_on: Date.new(2026, 10, 14))
    expect(AuditEvent.find_by!(target: activity).actor).to eq("human:operator")
  end

  describe "an agent" do
    let!(:application) { create(:application, posting: role, stage: "applied") }

    it "never starts an application or moves one, whatever it holds: refused, on the record" do
      expect { as_agent("agent:verifier") { application.update!(stage: "offer") } }
        .to raise_error(Authority::Denied, /may not update an application \(stage\)/)
      expect { as_agent("agent:suggester") { Application.create!(posting: create(:posting, company: company), company: company, stage: "applied", stage_changed_on: Date.current) } }
        .to raise_error(Authority::Denied)
      expect { as_agent("agent:verifier") { application.activities.create!(kind: "note", summary: "x", occurred_on: Date.current, logged_by: "agent:verifier") } }
        .to raise_error(Authority::Denied, /may not create an activity/)

      expect(application.reload.stage).to eq("applied")
      expect(AuditEvent.denied.count).to eq(3)
    end
  end
end
