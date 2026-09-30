require "rails_helper"

RSpec.describe Verifier::Resolution do
  describe ".targets" do
    it "sends each company's domain and name, and the page on record to try first" do
      company = create(:company, :with_careers_page, name: "Acme", domain: "acme.example")

      expect(described_class.targets([ company ])).to eq([
        { id: company.id, label: "Acme", domain: "acme.example", name: "Acme", known_url: "https://acme.example/careers" }
      ])
    end

    it "never sends an anonymised employer" do
      expect(described_class.targets([ create(:company, :without_domain, name: "Empresa Confidencial") ])).to be_empty
    end
  end

  describe ".mark_anonymised!" do
    it "records a withheld employer as a resolution failure, once" do
      placeholder = create(:company, :without_domain, name: "Confidential Company")
      real = create(:company, name: "Confidence Labs")

      expect(described_class.mark_anonymised!([ placeholder, real ])).to eq(1)
      expect(placeholder.reload).to have_attributes(resolution_status: "failed", resolution_failure: "anonymised")
      expect(real.reload.resolution_status).to be_nil
      expect(described_class.mark_anonymised!([ placeholder ])).to eq(0)
      expect(placeholder.audit_events.sole.actor).to eq("agent:verifier")
    end
  end

  describe ".ats_type" do
    let(:company) { build(:company, domain: "www.acme.example") }

    it "names a known ATS, the company's own site, or another host" do
      expect(described_class.ats_type(company, "https://jobs.lever.co/acme", "lever")).to eq("lever")
      expect(described_class.ats_type(company, "https://careers.acme.example/jobs", nil)).to eq("own_site")
      expect(described_class.ats_type(company, "https://acme.bamboohr.com/careers", nil)).to eq("other")
    end
  end
end
