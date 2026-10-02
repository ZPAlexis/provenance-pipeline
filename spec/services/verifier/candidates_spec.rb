require "rails_helper"

RSpec.describe Verifier::Candidates do
  let(:company) { create(:company, :resolution_candidate, domain: "acme.example") }

  describe ".confirm!" do
    it "makes the candidate the watched page, confirmed by a human" do
      described_class.confirm!(company)

      expect(company.reload).to have_attributes(
        careers_page_url: "https://acme.example/join", resolution_status: "resolved",
        resolution_confidence: "confirmed", resolution_candidate_url: nil, ats_type: "own_site"
      )
    end

    it "takes the ATS from the check that read the page" do
      company.update!(resolution_candidate_url: "https://jobs.lever.co/acme")
      create(:page_check, company: company, url: "https://jobs.lever.co/acme", ats_vendor: "lever", ats_board: "acme")

      described_class.confirm!(company)

      expect(company.reload.ats_type).to eq("lever")
    end

    it "is audited as the human who confirmed it" do
      described_class.confirm!(company)

      event = company.audit_events.sole
      expect(event).to have_attributes(actor: AuditEvent::OPERATOR, action: "update")
      expect(event.changes_made["resolution_confidence"]).to eq([ "low", "confirmed" ])
    end
  end

  describe ".reject!" do
    it "records the refusal as a failure, audited as the human" do
      described_class.reject!(company)

      expect(company.reload).to have_attributes(
        resolution_status: "failed", resolution_failure: "rejected", resolution_candidate_url: nil, careers_page_url: nil
      )
      expect(company.audit_events.sole.reasoning).to include("https://acme.example/join")
    end
  end

  it "refuses a company with no candidate" do
    resolved = create(:company, :resolved)

    expect { described_class.confirm!(resolved) }.to raise_error(described_class::NotACandidate)
    expect { described_class.reject!(resolved) }.to raise_error(described_class::NotACandidate)
  end

  it "lists the candidates waiting" do
    create(:company, :resolved)

    expect(described_class.pending).to contain_exactly(company)
  end

  # When the candidate is wrong and the human knows the right page.
  describe ".set_page!" do
    let(:reason) { "The Lever board's home-page link is another Arcadia; this is the company's own open-roles page." }

    it "makes a page the human found the watched one, replacing the candidate" do
      described_class.set_page!(company, "https://acme.example/openroles/", reasoning: reason)

      expect(company.reload).to have_attributes(
        careers_page_url: "https://acme.example/openroles/", ats_type: "own_site", resolution_status: "resolved",
        resolution_method: "manual", resolution_confidence: "confirmed", resolution_candidate_url: nil
      )
    end

    it "is audited as the human, with their reason" do
      described_class.set_page!(company, "https://acme.example/openroles/", reasoning: reason)

      event = company.audit_events.sole
      expect(event).to have_attributes(actor: AuditEvent::OPERATOR, action: "update")
      expect(event.reasoning).to eq("Set by hand. #{reason}")
      expect(event.changes_made["resolution_method"]).to eq([ "llm_link", "manual" ])
    end

    it "works whatever the company's state, naming a known ATS from the address" do
      failed = create(:company, resolution_status: "failed", resolution_failure: "not_found")

      described_class.set_page!(failed, "https://jobs.ashbyhq.com/acme", reasoning: reason)

      expect(failed.reload).to have_attributes(resolution_status: "resolved", resolution_failure: nil, ats_type: "ashby")
    end

    it "refuses an address that is not a web page, or no reason, writing nothing" do
      expect { described_class.set_page!(company, "acme.example/jobs", reasoning: reason) }.to raise_error(ArgumentError, /http/)
      expect { described_class.set_page!(company, "https://acme.example/jobs", reasoning: " ") }.to raise_error(ArgumentError, /reason/)
      expect(company.reload.resolution_status).to eq("candidate")
      expect(AuditEvent.count).to eq(0)
    end
  end

  describe ".set_kind!" do
    it "records the kind the operator judged, clearing the suggestion, audited as theirs" do
      company.update!(kind_suggestion: "recruiter", kind_evidence: "Its own page lists 30 roles at many employers.")

      described_class.set_kind!(company, "recruiter", reasoning: "A search firm: these are its client roles.")

      expect(company.reload).to have_attributes(kind: "recruiter", kind_suggestion: nil)
      event = company.audit_events.sole
      expect(event.actor).to eq(AuditEvent::OPERATOR)
      expect(event.reasoning).to eq("Kind set by hand: recruiter. A search firm: these are its client roles.")
    end

    it "refuses an unknown kind" do
      expect { described_class.set_kind!(company, "agency") }.to raise_error(ArgumentError, /kind is one of/)
    end
  end
end
