require "rails_helper"

RSpec.describe Company do
  describe "validations" do
    it "requires a name" do
      expect(build(:company, name: nil)).not_to be_valid
    end

    it "rejects a duplicate domain" do
      create(:company, domain: "acme.example")
      expect(build(:company, domain: "acme.example")).not_to be_valid
    end

    it "allows many companies without a domain" do
      create(:company, :without_domain)
      expect(build(:company, :without_domain)).to be_valid
    end

    it "accepts a known ATS type or none" do
      expect(build(:company, ats_type: "greenhouse")).to be_valid
      expect(build(:company, ats_type: nil)).to be_valid
    end

    it "rejects an unknown ATS type" do
      expect(build(:company, ats_type: "taleo")).not_to be_valid
    end
  end

  describe "scopes" do
    let!(:with_page) { create(:company, :with_careers_page) }
    let!(:without_page) { create(:company) }

    it "separates companies with and without a resolved careers page" do
      expect(described_class.with_careers_page).to contain_exactly(with_page)
      expect(described_class.needing_careers_page).to contain_exactly(without_page)
    end
  end

  describe ".find_or_create_for!" do
    it "creates a company with a normalized domain" do
      company = described_class.find_or_create_for!(name: "Acme", domain: "  ACME.example ")

      expect(company).to be_persisted
      expect(company.domain).to eq("acme.example")
    end

    it "matches an existing company on domain regardless of case, keeping its name" do
      existing = create(:company, name: "Acme Robotics", domain: "acme.example")

      expect {
        found = described_class.find_or_create_for!(name: "ACME Robotics Ltd", domain: "Acme.Example")
        expect(found).to eq(existing)
        expect(found.name).to eq("Acme Robotics")
      }.not_to change(described_class, :count)
    end

    it "falls back to the stripped name when no domain is given" do
      existing = create(:company, :without_domain, name: "Nameless Co")

      expect(described_class.find_or_create_for!(name: " Nameless Co ", domain: "")).to eq(existing)
    end

    it "creates a domainless company when no name matches" do
      expect {
        described_class.find_or_create_for!(name: "Brand New Co", domain: nil)
      }.to change(described_class, :count).by(1)
    end
  end

  describe "deletion" do
    let(:company) { create(:company) }

    it "destroys its postings" do
      create(:posting, company: company)
      expect { company.destroy }.to change(Posting, :count).by(-1)
    end

    # The audit trail outlives the records it describes.
    it "keeps audit events about it and about its postings" do
      posting = create(:posting, company: company)
      company_event = create(:audit_event, target: company)
      posting_event = create(:audit_event, target: posting)

      expect { company.destroy }.not_to change(AuditEvent, :count)
      expect(company_event.reload.target_id).to be_nil
      expect(posting_event.reload.target_id).to be_nil
    end
  end
end
