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
    expect { described_class.dismiss!(posting, note: " ") }.to raise_error(ArgumentError, /say why/)
    expect { described_class.track!(posting, note: "Again.") }.to raise_error(ArgumentError, "already tracked")
    expect(posting.audit_events).to be_empty
  end

  # 4a: a company is tracked or archived by the operator, as a role is; archiving one archives its roles in play.
  describe "companies" do
    let(:company) { create(:company, :resolved, name: "Acme", domain: "acme.example") }
    let!(:tracked) { create(:posting, company: company, role_title: "Sales Engineer") }
    let!(:suggested) { create(:posting, company: company, role_title: "Solutions Engineer", tracking: "suggested", fit: { "title" => "Solutions Engineer" }) }

    it "archives a company and its roles in play, each with the note, and the company is no longer watched" do
      gone = create(:posting, company: company, role_title: "Recruiter", tracking: "dismissed")

      roles = described_class.dismiss_company!(company, note: "Not hiring in my field.")

      expect(roles).to contain_exactly(tracked, suggested)
      expect(company.reload).to be_dismissed
      expect(Company.watched).not_to include(company)
      expect([ tracked, suggested, gone ].map { |role| role.reload.tracking }).to all(eq("dismissed"))
      expect(company.audit_events.sole).to have_attributes(actor: AuditEvent::OPERATOR, changes_made: { "tracking" => %w[tracked dismissed] },
                                                           reasoning: "Archived by hand: never checked, suggested from or reviewed again. " \
                                                                      "Not hiring in my field.")
      expect(tracked.audit_events.sole.reasoning).to eq("Archived with its company: Not hiring in my field.")
      expect(gone.audit_events).to be_empty
    end

    it "brings back, when tracked again, the roles archived with it as they were, never one archived another time" do
      on_its_own = create(:posting, company: company, role_title: "Account Executive")
      later { described_class.dismiss!(on_its_own, note: "Not for me.") }
      later { described_class.dismiss_company!(company, note: "Pausing.") }

      back = later { described_class.track_company!(company, note: "Hiring again.") }

      expect(back).to contain_exactly(tracked, suggested)
      expect([ tracked.reload.tracking, suggested.reload.tracking, on_its_own.reload.tracking ]).to eq(%w[tracked suggested dismissed])
      expect(tracked.audit_events.order(:occurred_at).last.reasoning).to eq("Back with its company: Hiring again.")

      # Tracked again without its roles, then archived again: the roles of the first archiving stay archived.
      later { described_class.dismiss_company!(company, note: "Pausing.") }
      later { described_class.track_company!(company, note: "Just the company.", with_roles: false) }
      fresh = create(:posting, company: company, role_title: "Partner Manager")
      later { described_class.dismiss_company!(company, note: "Pausing again.") }
      expect(later { described_class.track_company!(company, note: "Back.") }).to eq([ fresh ])
      expect(tracked.reload.tracking).to eq("dismissed")
    end

    it "refuses with an open application, without a note, or when already so; a closed application doesn't stop it" do
      application = create(:application, posting: tracked, company: company, stage: "applied")

      expect { described_class.dismiss_company!(company, note: "Done.") }
        .to raise_error(ArgumentError, "Acme has an open application (Sales Engineer): close or withdraw it first")
      application.update!(stage: "withdrawn")
      expect { described_class.dismiss_company!(company, note: " ") }.to raise_error(ArgumentError, /say why/)
      expect { described_class.track_company!(company, note: "Again.") }.to raise_error(ArgumentError, "Acme is already tracked")

      described_class.dismiss_company!(company, note: "Done.")
      expect { described_class.dismiss_company!(company, note: "Again.") }.to raise_error(ArgumentError, "Acme is already archived")
    end

    it "spares an archived company every check, suggestion and review question" do
      unresolved = create(:company, name: "Beta", domain: "beta.example", resolution_status: "failed", resolution_failure: "blocked")
      create(:posting, company: unresolved, role_title: "Recruiter")
      ReviewQueue.sync!(unresolved)
      item = unresolved.review_items.open.sole

      described_class.dismiss_company!(unresolved, note: "Not for me.")
      described_class.dismiss_company!(company, note: "Not for me.")

      expect(item.reload).to have_attributes(status: "done", decision: "resolved")
      expect(item.audit_events.order(:occurred_at).last.reasoning).to eq("Resolved: its company is archived.")
      ReviewQueue.sync!(unresolved)
      expect(unresolved.review_items.open).to be_empty
      expect(Verifier::CheckAll.companies).not_to include(company)
      expect(Verifier::CheckNow.refusal(company)).to eq("Acme is archived: track it again to check it.")
      read = create(:page_check, company: company, purpose: "verification")
      expect { Verifier::Suggestions.propose!("#{read.id}:0", why: "It fits.") }
        .to raise_error(ArgumentError, "Acme is archived: track it again before suggesting its roles")
    end

    it "lets no agent track or archive a company, nor propose a role at an archived one" do
      described_class.dismiss_company!(company, note: "Not for me.")

      expect { as_agent("agent:clay_importer") { company.update!(tracking: "tracked") } }.to raise_error(Authority::Denied)
      company.reload # the refused update left its value in memory, not on record
      expect { as_agent("agent:suggester") { company.postings.create!(role_title: "New", tracking: "suggested", fit: { "title" => "New" }) } }
        .to raise_error(Authority::Denied)
    end
  end
end
