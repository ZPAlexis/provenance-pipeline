require "rails_helper"

RSpec.describe ReviewQueue do
  let(:company) { create(:company, :resolved, name: "Acme", domain: "acme.example") }

  def open_items(record = company) = record.review_items.open.pluck(:kind, :evidence_key, :proposal)

  describe "a careers page found at low confidence" do
    let(:company) { create(:company, :resolution_candidate, name: "Acme", domain: "acme.example") }

    it "is raised by the verifier with what was seen, and closed as the operator's when they confirm it" do
      described_class.sync!(company)

      item = company.review_items.open.sole
      expect(item).to have_attributes(kind: "careers_page_candidate", proposal: "confirm", raised_by: "agent:verifier",
                                      evidence_key: "https://acme.example/join")
      expect(item.evidence).to start_with("Found by llm_link at low confidence: https://acme.example/join.")
      expect(AuditEvent.find_by!(target: item)).to have_attributes(actor: "agent:verifier", action: "create")

      Verifier::Candidates.confirm!(company)

      expect(item.reload).to have_attributes(status: "done", decision: "resolved", decided_by: "human:operator")
      expect(company.review_items.open).to be_empty
    end
  end

  it "asks a company's kind when its pages suggest one and none is set" do
    company.update!(kind_suggestion: "recruiter", kind_evidence: "Lists roles at 30 employers.")

    described_class.sync!(company)

    expect(open_items).to eq([ [ "company_kind", "recruiter", "set_kind:recruiter" ] ])
  end

  it "asks where a company lists its roles when none was found, never when the operator rejected one" do
    missing = create(:company, resolution_status: "failed", resolution_failure: "not_found")
    blocked = create(:company, resolution_status: "failed", resolution_failure: "blocked")
    rejected = create(:company, resolution_status: "failed", resolution_failure: "rejected")

    [ missing, blocked, rejected ].each { |record| described_class.sync!(record) }

    expect(open_items(missing)).to eq([ [ "no_careers_page", "not_found", "find_again" ] ])
    expect(open_items(blocked)).to eq([ [ "no_careers_page", "blocked", "set_page" ] ])
    expect(open_items(rejected)).to be_empty
  end

  describe "a watched list read only in part" do
    before do
      create(:posting, company: company, role_title: "Sales Engineer")
      create(:page_check, company: company, purpose: "verification", step: nil, url: company.careers_page_url, run_id: "r1",
                          checked_at: 1.day.ago, listings_incomplete: true, stated_total: 113)
    end

    it "is raised once per page, and an item left stays left until the page changes" do
      described_class.sync!(company)
      item = company.review_items.open.sole
      expect(item).to have_attributes(kind: "partial_list", proposal: "set_page", evidence_key: company.careers_page_url)
      expect(item.evidence).to include("Read 1 of 113 roles")

      item.update!(status: "left", decided_by: "human:operator")
      create(:page_check, company: company, purpose: "verification", step: nil, url: company.careers_page_url, run_id: "r2",
                          checked_at: Time.current, listings_incomplete: true)
      described_class.sync!(company)
      expect(company.review_items.open).to be_empty # the same page read in part again: not new evidence

      company.update!(careers_page_url: "https://acme.example/jobs")
      create(:page_check, company: company, purpose: "verification", step: nil, url: company.careers_page_url, run_id: "r3",
                          checked_at: Time.current, listings_incomplete: true)
      described_class.sync!(company)
      expect(open_items).to eq([ [ "partial_list", "https://acme.example/jobs", "set_page" ] ])
    end

    it "is not asked when the page's own stated total was read in full, whatever its flag says" do
      company.page_checks.update_all(stated_total: 1) # one role read of the one it states

      described_class.sync!(company)

      expect(company.review_items.open).to be_empty
    end

    it "is not asked once no role is in play there" do
      company.postings.update_all(tracking: "dismissed")

      described_class.sync!(company)

      expect(company.review_items.open).to be_empty
    end
  end

  describe "a role's answer" do
    it "is suspect when no longer listed came from a read that saw no roles, until the operator checks it by hand" do
      posting = create(:posting, :suspect_negative, company: company, role_title: "Sales Engineer")
      AuditEvent.record!(actor: "agent:verifier", action: "update", target: posting, changes_made: { "last_checked_at" => [ nil, 1 ] })

      described_class.sync!(company)
      item = company.review_items.open.sole
      expect(item).to have_attributes(kind: "suspect_verdict", subject: posting, proposal: "hand_check")

      Verifier::HandCheck.record!(posting, verdict: "verified_live", note: "Its page lists it.")

      expect(item.reload).to have_attributes(status: "done", decided_by: "human:operator")
      expect(company.review_items.open).to be_empty # the operator's own answer is never raised
    end

    it "is suspect when still listed rests on the AI's judgment alone" do
      posting = create(:posting, :verified_live, company: company, role_title: "Sales Engineer")
      create(:page_check, company: company, purpose: "verification", step: nil, checked_at: 1.hour.ago,
                          matches: [ { "posting_id" => posting.id, "verdict" => "verified_live", "method" => "llm",
                                       "reasoning" => "The AI judged \"Sr. Sales Engineer\" the same role." } ])

      described_class.sync!(company)

      expect(company.review_items.open.sole.evidence).to eq(
        "Marked still listed on the AI's judgment alone. The AI judged \"Sr. Sales Engineer\" the same role."
      )
    end

    it "asks to check again a role that couldn't be confirmed, and closes when the role is dismissed" do
      posting = create(:posting, company: company, role_title: "Sales Engineer", verification_state: "inaccessible",
                                 last_checked_at: 1.day.ago)

      described_class.sync!(company)
      expect(open_items).to eq([ [ "unconfirmed_role", "inaccessible", "check_again" ] ])

      Verifier::Tracking.dismiss!(posting, note: "Not for me.")
      expect(company.review_items.open).to be_empty
    end
  end

  it "never raises the same question twice" do
    company.update!(kind_suggestion: "recruiter")

    2.times { described_class.sync!(company) }

    expect(company.review_items.count).to eq(1)
  end

  it "is kept in step by the verifier's own reads" do
    candidate = create(:company, name: "Beta", domain: "beta.example")
    result = { "kind" => "resolution", "target_id" => candidate.id, "outcome" => "candidate", "method" => "llm_link",
               "confidence" => "low", "careers_page_url" => "https://beta.example/careers", "checks" => [] }

    Verifier::Ingest.new(run_id: "r1").resolution(result)

    expect(candidate.review_items.open.sole).to have_attributes(kind: "careers_page_candidate")
  end
end
