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
end
