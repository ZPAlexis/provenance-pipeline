require "rails_helper"

# Fixtures under spec/fixtures/files/clay/ are synthetic but mirror the real
# Clay exports byte for byte: no BOM, CRLF, non-empty fields quoted, and the
# leading "search" column Clay prepends. Real exports are never committed.
RSpec.describe ClayImporter do
  let(:sourcing_csv) { file_fixture("clay/GTM-Testland-export-1000000000001.csv") }
  let(:research_csv) { file_fixture("clay/GTM-Researchland-export-1000000000002.csv") }

  def posting_for(title)
    Posting.find_by!(role_title: title)
  end

  describe "a 7-column sourcing export" do
    subject(:result) { described_class.call(sourcing_csv) }

    it "reports what it did" do
      expect(result).to have_attributes(
        rows: 5, companies_created: 3, companies_matched: 1,
        postings_created: 4, postings_skipped: 0, errors: []
      )
    end

    it "tags every posting with the slice named in the filename" do
      result
      expect(Posting.distinct.pluck(:source_slice)).to eq([ "testland" ])
    end

    it "dedupes companies on domain regardless of case, keeping every posting" do
      result
      acme = Company.find_by!(domain: "acme.example")

      expect(Company.where(name: "Acme Robotics").count).to eq(1)
      expect(acme.postings.pluck(:role_title)).to contain_exactly("RevOps Engineer", "GTM Systems Analyst")
    end

    it "falls back to the company name when the domain is missing" do
      result
      expect(Company.find_by!(name: "Nameless Co").domain).to be_nil
    end

    it "skips rows without a company name" do
      result
      expect(Posting.where(role_title: "Orphan Role")).to be_empty
      expect(Company.where(domain: "orphan.example")).to be_empty
    end

    it "parses posting dates and tolerates unparseable ones" do
      result
      expect(posting_for("RevOps Engineer").posted_on).to eq(Date.new(2026, 9, 1))
      expect(posting_for("Data Engineer").posted_on).to be_nil
    end

    it "leaves unresearched postings pending with no verification evidence" do
      result
      expect(Posting.all).to all(have_attributes(
        verification_state: "pending", roles_listed_count: nil, work_mode: nil, last_checked_at: nil
      ))
    end

    it "records one audit event per record it creates, as its own actor" do
      result

      expect(AuditEvent.count).to eq(3 + 4)
      expect(AuditEvent.distinct.pluck(:actor)).to eq([ described_class::ACTOR ])
      expect(AuditEvent.distinct.pluck(:action)).to eq([ "create" ])
    end

    it "explains unverified postings in the audit reasoning" do
      result
      event = AuditEvent.find_by!(target: posting_for("Solutions Engineer"))

      expect(event.reasoning).to include("GTM-Testland-export-1000000000001.csv", "testland", "Not yet verified")
    end

    context "when imported a second time" do
      before { described_class.call(sourcing_csv) }

      it "creates no duplicate records" do
        expect { described_class.call(sourcing_csv) }
          .to not_change(Company, :count).and not_change(Posting, :count)
      end

      it "skips every posting it already has" do
        expect(described_class.call(sourcing_csv).postings_skipped).to eq(4)
      end

      it "writes nothing to the audit log" do
        pending "A2: a domainless company matched by name is still recorded as a new create"
        expect { described_class.call(sourcing_csv) }.not_to change(AuditEvent, :count)
      end
    end

    it "does not record a create for a domainless company it matched by name" do
      pending "A2: `existed` is only computed when a domain is present"
      create(:company, :without_domain, name: "Nameless Co")

      expect(result).to have_attributes(companies_created: 2, companies_matched: 2)
    end
  end

  describe "a 28-column research-enriched export" do
    subject(:result) { described_class.call(research_csv) }

    it "reports what it did" do
      expect(result).to have_attributes(
        rows: 9, companies_created: 8, companies_matched: 1,
        postings_created: 9, postings_skipped: 0, errors: []
      )
    end

    it "carries the verdict, corroborating count, and work mode onto the posting" do
      result
      expect(posting_for("Senior RevOps Engineer")).to have_attributes(
        verification_state: "verified_live", roles_listed_count: 12, work_mode: "remote"
      )
    end

    it "normalizes case and whitespace in upstream values" do
      result
      expect(posting_for("Operations Analyst")).to have_attributes(
        verification_state: "verified_live", work_mode: "remote"
      )
    end

    it "falls back to pending on an unrecognized verdict, preserving the original" do
      result
      posting = posting_for("Systems Analyst")

      expect(posting.verification_state).to eq("pending")
      expect(posting.work_mode).to be_nil
      expect(posting.enrichment["raw_verification"]).to eq("probably_live")
    end

    it "stores a negative \"could not count\" sentinel as unknown, preserving the original" do
      result
      posting = posting_for("Revenue Systems Lead")

      expect(posting).to have_attributes(verification_state: "verified_live", roles_listed_count: nil)
      expect(posting.enrichment["raw_roles_listed_count"]).to eq("-1")
    end

    it "preserves the corroborating observable that separates negatives" do
      result
      expect(Posting.credible_negatives).to contain_exactly(posting_for("GTM Engineer"))
      expect(Posting.suspect_negatives).to contain_exactly(posting_for("Solutions Architect"))
    end

    it "marks researched postings as checked and leaves unresearched ones alone" do
      result
      expect(posting_for("Senior RevOps Engineer").last_checked_at).to be_present
      expect(posting_for("Data Engineer")).to have_attributes(verification_state: "pending", last_checked_at: nil)
    end

    it "keeps research evidence on the posting" do
      result
      expect(posting_for("Senior RevOps Engineer").enrichment).to include(
        "hiring_evidence" => "Careers page lists the role.",
        "verified_role_title" => "Senior RevOps Engineer"
      )
    end

    it "uses the researcher's prose reasoning as the audit reasoning" do
      result
      event = AuditEvent.find_by!(target: posting_for("GTM Engineer"))

      expect(event.reasoning).to eq("Careers page lists 23 roles; this one is not among them.")
    end

    it "sets the careers page on first sight and never overwrites it" do
      result
      expect(Company.find_by!(domain: "initech.example").careers_page_url).to eq("https://initech.example/careers")
    end

    it "keeps unmapped columns in the company's enrichment instead of dropping them" do
      result
      expect(Company.find_by!(domain: "initech.example").enrichment).to include("Employee Count" => "120")
    end
  end

  describe "importing sourcing and research pulls that overlap" do
    it "fills in a careers page for a company first seen without one" do
      described_class.call(sourcing_csv)
      expect(Company.find_by!(domain: "acme.example").careers_page_url).to be_nil

      result = described_class.call(research_csv)

      expect(result).to have_attributes(companies_created: 7, companies_matched: 2)
      expect(Company.find_by!(domain: "acme.example").careers_page_url).to eq("https://acme.example/careers")
    end
  end

  describe "a row that fails" do
    it "is reported with its row number while the rest of the file imports" do
      allow(Posting).to receive(:create!).and_wrap_original do |original, *args, **kwargs|
        attrs = args.first || kwargs
        raise "simulated failure" if attrs[:role_title] == "Data Engineer"

        original.call(*args, **kwargs)
      end

      result = described_class.call(sourcing_csv)

      expect(result.errors).to eq([ { row: 4, error: "simulated failure" } ])
      expect(result.postings_created).to eq(3)
    end
  end

  describe ".import_dir" do
    it "imports every CSV in the directory in filename order" do
      results = described_class.import_dir(file_fixture("clay"))

      expect(results.map(&:first)).to eq(%w[
        GTM-Researchland-export-1000000000002.csv
        GTM-Testland-export-1000000000001.csv
      ])
      expect(results.map(&:last)).to all(have_attributes(errors: []))
    end
  end
end
