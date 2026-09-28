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

  def company_at(domain)
    Company.find_by!(domain: domain)
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

      expect(Company.where(name: "Acme Robotics").count).to eq(1)
      expect(company_at("acme.example").postings.pluck(:role_title))
        .to contain_exactly("RevOps Engineer", "GTM Systems Analyst")
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

    it "records one create event per record, as its own actor, and nothing for an unchanged match" do
      result

      expect(AuditEvent.count).to eq(3 + 4)
      expect(AuditEvent.distinct.pluck(:actor)).to eq([ described_class::ACTOR ])
      expect(AuditEvent.distinct.pluck(:action)).to eq([ "create" ])
    end

    it "records what each company create set, as before/after pairs" do
      result
      event = AuditEvent.find_by!(target: company_at("acme.example"))

      expect(event.changes_made).to eq("name" => [ nil, "Acme Robotics" ], "domain" => [ nil, "acme.example" ])
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
        expect { described_class.call(sourcing_csv) }.not_to change(AuditEvent, :count)
      end
    end

    it "does not record a create for a domainless company it matched by name" do
      create(:company, :without_domain, name: "Nameless Co")

      expect(result).to have_attributes(companies_created: 2, companies_matched: 2)
      expect(AuditEvent.where(target_type: "Company").count).to eq(2)
    end
  end

  describe "a 28-column research-enriched export" do
    subject(:result) { described_class.call(research_csv, verified_at: "2026-09-22") }

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

    it "keeps research evidence on the posting" do
      result
      expect(posting_for("Senior RevOps Engineer").enrichment).to include(
        "hiring_evidence" => "Careers page lists the role.",
        "verified_role_title" => "Senior RevOps Engineer"
      )
    end

    # Each research run is an observation made while checking one posting, and
    # two runs at the same employer can disagree. Both answers survive, each on
    # the posting that produced it, beside that run's reasoning.
    it "keeps each research run's output on the posting it checked" do
      result

      expect(posting_for("Senior RevOps Engineer").enrichment).to include(
        "Career Search - Prospecting Researcher" => "Run 201",
        "Career Search Prospecting Researcher Evidence Url" => "https://initech.example/careers/201",
        "Career Search Prospecting Researcher Industry" => "Software",
        "careers_page_url" => "https://initech.example/careers"
      )
      expect(posting_for("RevOps Analyst").enrichment).to include(
        "Career Search Prospecting Researcher Evidence Url" => "https://initech.example/careers/207",
        "Career Search Prospecting Researcher Industry" => "Enterprise Software",
        "careers_page_url" => "https://initech.example/other-careers"
      )
    end

    it "keeps no research-agent output on the company" do
      result
      expect(Company.all.flat_map { |c| c.enrichment.keys }).to all(satisfy { |key| !key.start_with?("Career Search") })
    end

    it "keeps company-level columns in the company's enrichment instead of dropping them" do
      result
      expect(company_at("initech.example").enrichment).to include("Employee Count" => "120")
    end

    # Company facts are seeded once. Refreshing them is the enrichment agent's
    # job, under its own audit trail — not a side effect of re-reading an export.
    it "never overwrites a company-level value already set" do
      result
      expect(company_at("initech.example").enrichment["Employee Count"]).to eq("120")
    end

    it "uses the researcher's prose reasoning as the audit reasoning" do
      result
      event = AuditEvent.find_by!(target: posting_for("GTM Engineer"))

      expect(event.reasoning).to start_with("Careers page lists 23 roles; this one is not among them.")
    end

    it "records each posting create as a snapshot of what the import set" do
      result
      event = AuditEvent.find_by!(target: posting_for("GTM Engineer"))

      expect(event.changes_made).to include(
        "verification_state" => [ nil, "not_found" ],
        "roles_listed_count" => [ nil, 23 ],
        "source_slice" => [ nil, "researchland" ]
      )
    end

    it "sets the careers page on first sight and never overwrites it" do
      result
      expect(company_at("initech.example").careers_page_url).to eq("https://initech.example/careers")
    end

    it "records a company created from a research row in one event, careers page included" do
      result
      events = AuditEvent.where(target: company_at("hooli.example"))

      expect(events.pluck(:action)).to eq([ "create" ])
      expect(events.first.changes_made).to include("careers_page_url" => [ nil, "https://hooli.example/jobs" ])
    end

    it "records a later row filling in a company-level column as an update" do
      result
      update = AuditEvent.find_by!(target: company_at("initech.example"), action: "update")

      expect(update.changes_made).to eq("enrichment" => { "Founded" => [ nil, "1999" ] })
      expect(update.actor).to eq(described_class::ACTOR)
      expect(update.reasoning).to include("GTM-Researchland-export-1000000000002.csv")
    end

    it "audits every write: one create per record plus one update per changed match" do
      result
      expect(AuditEvent.group(:action).count).to eq("create" => 8 + 9, "update" => 1)
    end

    # Two research runs at one employer can disagree. Re-importing must not
    # flip the company between their answers and log churn as real changes.
    it "writes nothing to the audit log when imported a second time" do
      result
      expect { described_class.call(research_csv, verified_at: "2026-09-22") }.not_to change(AuditEvent, :count)
    end
  end

  # A check is an observation at the employer's careers page that produced a
  # recognized verdict, and last_checked_at is set exactly when a posting has
  # one. Clay exports carry no per-row check date, so the operator supplies it.
  describe "check dates" do
    def reasoning_for(title)
      AuditEvent.find_by!(target: posting_for(title)).reasoning
    end

    it "stamps each recognized verdict with the supplied date, at noon UTC so the calendar day never shifts" do
      described_class.call(research_csv, verified_at: "2026-09-22")

      expect(posting_for("Senior RevOps Engineer").last_checked_at).to eq(Time.utc(2026, 9, 22, 12))
      expect(posting_for("Data Engineer").last_checked_at).to be_nil
    end

    it "keeps a full timestamp as given" do
      described_class.call(research_csv, verified_at: "2026-09-22T15:30:00Z")
      expect(posting_for("GTM Engineer").last_checked_at).to eq(Time.utc(2026, 9, 22, 15, 30))
    end

    it "does not count an unrecognized verdict as a check" do
      described_class.call(research_csv, verified_at: "2026-09-22")
      expect(posting_for("Systems Analyst")).to have_attributes(verification_state: "pending", last_checked_at: nil)
    end

    it "says in the create event that the operator supplied the date, and at day precision" do
      described_class.call(research_csv, verified_at: "2026-09-22")
      expect(reasoning_for("GTM Engineer")).to include("VERIFIED_AT", "operator", "2026-09-22", "day precision")
    end

    it "does not call an operator-supplied full timestamp day precision" do
      described_class.call(research_csv, verified_at: "2026-09-22T15:30:00Z")

      expect(reasoning_for("GTM Engineer")).to include("VERIFIED_AT", "2026-09-22T15:30:00Z")
      expect(reasoning_for("GTM Engineer")).not_to include("day precision")
    end

    it "adds no date note to a posting without a verdict" do
      described_class.call(research_csv, verified_at: "2026-09-22")
      expect(reasoning_for("Data Engineer")).not_to include("VERIFIED_AT")
    end

    it "refuses an export with verdicts when no date is supplied, before writing anything" do
      expect { described_class.call(research_csv) }
        .to raise_error(described_class::MissingVerifiedAt, /GTM-Researchland-export-1000000000002\.csv.*VERIFIED_AT/)
      expect([ Company.count, Posting.count, AuditEvent.count ]).to eq([ 0, 0, 0 ])
    end

    it "needs no date for an export without verdicts" do
      expect(described_class.call(sourcing_csv).errors).to be_empty
    end

    it "needs no date when an export's only verdicts are unrecognized" do
      Dir.mktmpdir do |dir|
        header, *rows = File.readlines(research_csv)
        path = File.join(dir, "GTM-Researchland-export-1.csv")
        File.write(path, header + rows.grep(/umbrella\.example/).join)

        expect(described_class.call(path).errors).to be_empty
      end
      expect(posting_for("Systems Analyst").last_checked_at).to be_nil
    end

    it "checks a whole directory before importing any of it" do
      Dir.mktmpdir do |dir|
        FileUtils.cp(sourcing_csv, File.join(dir, "GTM-Alpha-export-1.csv"))
        FileUtils.cp(research_csv, File.join(dir, "GTM-Beta-export-2.csv"))

        expect { described_class.import_dir(dir) }.to raise_error(described_class::MissingVerifiedAt)
      end
      expect(Posting.count).to eq(0)
    end

    it "rejects a date that is not ISO 8601" do
      expect { described_class.call(research_csv, verified_at: "last tuesday") }.to raise_error(ArgumentError)
    end
  end

  describe "importing sourcing and research pulls that overlap" do
    it "fills in a careers page for a company first seen without one, and records it" do
      described_class.call(sourcing_csv)
      expect(company_at("acme.example").careers_page_url).to be_nil

      result = described_class.call(research_csv, verified_at: "2026-09-22")
      update = AuditEvent.find_by!(target: company_at("acme.example"), action: "update")

      expect(result).to have_attributes(companies_created: 7, companies_matched: 2)
      expect(company_at("acme.example").careers_page_url).to eq("https://acme.example/careers")
      expect(update.changes_made).to eq("careers_page_url" => [ nil, "https://acme.example/careers" ])
    end
  end

  describe "a row that fails" do
    before do
      allow(Posting).to receive(:create!).and_wrap_original do |original, *args, **kwargs|
        attrs = args.first || kwargs
        raise "simulated failure" if attrs[:role_title] == "Data Engineer"

        original.call(*args, **kwargs)
      end
    end

    it "is reported with its row number while the rest of the file imports" do
      result = described_class.call(sourcing_csv)

      expect(result.errors).to eq([ { row: 4, error: "simulated failure" } ])
      expect(result.postings_created).to eq(3)
    end

    # Rows are atomic: a failed posting must not leave behind the company it
    # created, or an audit event for a write that was rolled back.
    it "writes nothing at all for that row" do
      result = described_class.call(sourcing_csv)

      expect(Company.where(name: "Nameless Co")).to be_empty
      expect(AuditEvent.count).to eq(2 + 3)
      expect(result).to have_attributes(companies_created: 2, companies_matched: 1)
    end
  end

  describe "source slice" do
    it "is derived from a filename without the Clay export suffix, minus the extension" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "Testland.csv")
        FileUtils.cp(sourcing_csv, path)
        described_class.call(path)
      end

      expect(Posting.distinct.pluck(:source_slice)).to eq([ "testland" ])
    end
  end

  describe ".import_dir" do
    it "imports every CSV in the directory in filename order" do
      results = described_class.import_dir(file_fixture("clay"), verified_at: "2026-09-22")

      expect(results.map(&:first)).to eq(%w[
        GTM-Researchland-export-1000000000002.csv
        GTM-Testland-export-1000000000001.csv
      ])
      expect(results.map(&:last)).to all(have_attributes(errors: []))
    end
  end
end
