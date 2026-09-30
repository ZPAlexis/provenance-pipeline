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

    it "knows Workday" do
      expect(build(:company, ats_type: "workday")).to be_valid
    end
  end

  # Each resolution state carries the fields that make it meaningful, enforced
  # here so no writer can leave a company half-resolved.
  describe "careers-page resolution" do
    it "starts unresolved" do
      expect(build(:company)).to have_attributes(resolution_status: nil)
    end

    it "is resolved only with a careers page, a method, and a confidence" do
      expect(build(:company, :resolved)).to be_valid
      expect(build(:company, :resolved, careers_page_url: nil)).not_to be_valid
      expect(build(:company, :resolved, resolution_method: nil)).not_to be_valid
      expect(build(:company, :resolved, resolution_confidence: nil)).not_to be_valid
    end

    # A low-confidence find waits for a human: it is held as a candidate, never
    # written as the page the system watches.
    it "holds a low-confidence find as a candidate, not as the watched page" do
      expect(build(:company, :resolution_candidate)).to be_valid
      expect(build(:company, :resolution_candidate, resolution_candidate_url: nil)).not_to be_valid
    end

    it "records why a resolution failed" do
      expect(build(:company, resolution_status: "failed", resolution_failure: "no_domain")).to be_valid
      expect(build(:company, resolution_status: "failed", resolution_failure: nil)).not_to be_valid
    end

    it "accepts only known statuses, methods, confidences, and failure reasons" do
      expect(build(:company, :resolved, resolution_method: "hunch")).not_to be_valid
      expect(build(:company, :resolved, resolution_confidence: "certain")).not_to be_valid
      expect(build(:company, resolution_status: "failed", resolution_failure: "bad_luck")).not_to be_valid
      expect(build(:company, resolution_status: "pending")).not_to be_valid
    end

    it "separates companies still to resolve from candidates awaiting confirmation" do
      unresolved = create(:company)
      candidate = create(:company, :resolution_candidate)
      create(:company, :resolved)

      expect(described_class.unresolved).to contain_exactly(unresolved)
      expect(described_class.resolution_candidates).to contain_exactly(candidate)
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

  # Returns an unsaved record when nothing matches, so the caller can set every
  # attribute and save once — one write, one audit event — and can tell a
  # create from a match without a second lookup.
  describe ".find_or_initialize_for" do
    it "initializes an unsaved company with a normalized domain and name" do
      company = described_class.find_or_initialize_for(name: " Acme ", domain: "  ACME.example ")

      expect(company).to be_new_record
      expect(company).to have_attributes(name: "Acme", domain: "acme.example")
    end

    it "matches an existing company on domain regardless of case, keeping its name" do
      existing = create(:company, name: "Acme Robotics", domain: "acme.example")
      found = described_class.find_or_initialize_for(name: "ACME Robotics Ltd", domain: "Acme.Example")

      expect(found).to eq(existing)
      expect(found).to have_attributes(persisted?: true, name: "Acme Robotics")
    end

    it "falls back to the stripped name when no domain is given" do
      existing = create(:company, :without_domain, name: "Nameless Co")

      expect(described_class.find_or_initialize_for(name: " Nameless Co ", domain: "")).to eq(existing)
    end

    it "initializes a domainless company when no name matches" do
      company = described_class.find_or_initialize_for(name: "Brand New Co", domain: nil)

      expect(company).to be_new_record
      expect(company.domain).to be_nil
    end
  end

  describe "deletion" do
    let(:company) { create(:company) }

    it "destroys its postings" do
      create(:posting, company: company)
      expect { company.destroy }.to change(Posting, :count).by(-1)
    end

    # The audit trail outlives the records it describes, untouched: events keep
    # both target_type and target_id, so a deleted record's history stays
    # queryable by id and no event is modified after it is written.
    it "leaves audit events about it and its postings exactly as written" do
      posting = create(:posting, company: company)
      company_event = create(:audit_event, target: company)
      posting_event = create(:audit_event, target: posting)

      expect { company.destroy }.not_to change(AuditEvent, :count)
      expect(company_event.reload).to have_attributes(target_type: "Company", target_id: company.id, target: nil)
      expect(posting_event.reload).to have_attributes(target_type: "Posting", target_id: posting.id, target: nil)
    end

    it "keeps a deleted record's whole history linked by its id" do
      create(:audit_event, target: company, action: "create")
      create(:audit_event, target: company, action: "update")
      company.destroy

      history = AuditEvent.where(target_type: "Company", target_id: company.id)
      expect(history.pluck(:action)).to contain_exactly("create", "update")
    end
  end
end
