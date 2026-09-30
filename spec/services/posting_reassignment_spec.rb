require "rails_helper"

RSpec.describe PostingReassignment do
  let(:aggregator) do
    create(:company, name: "Jobs Everywhere", domain: "jobs-everywhere.example",
                     careers_page_url: "https://ats.example/acme/jobs")
  end
  let(:posting) do
    create(:posting, company: aggregator, enrichment: { "careers_page_url" => "https://ats.example/acme/jobs" })
  end

  def move(**options)
    described_class.call(posting, name: "Acme", domain: "acme.example", actor: AuditEvent::OPERATOR,
                                  reasoning: "Research found Acme is the employer.", **options)
  end

  it "moves the posting to the real employer, creating it" do
    employer = move

    expect(posting.reload.company).to eq(employer)
    expect(employer).to have_attributes(name: "Acme", domain: "acme.example")
  end

  it "carries the careers page its research found, and clears it from the aggregator" do
    employer = move

    expect(employer.careers_page_url).to eq("https://ats.example/acme/jobs")
    expect(aggregator.reload.careers_page_url).to be_nil
  end

  it "leaves the aggregator's careers page alone when it did not come from this posting" do
    posting.update!(enrichment: {})

    expect(move.careers_page_url).to be_nil
    expect(aggregator.reload.careers_page_url).to eq("https://ats.example/acme/jobs")
  end

  it "moves to a company it already has, never overwriting its careers page" do
    existing = create(:company, name: "Acme", domain: "acme.example", careers_page_url: "https://acme.example/careers")

    expect(move).to eq(existing)
    expect(existing.reload.careers_page_url).to eq("https://acme.example/careers")
  end

  it "audits every write as the human who decided, with their reason" do
    posting
    expect { move }.to change(AuditEvent, :count).by(3)

    events = AuditEvent.order(:occurred_at).last(3)
    expect(events.map(&:actor).uniq).to eq([ AuditEvent::OPERATOR ])
    expect(events.map(&:reasoning)).to all(include("Research found Acme is the employer."))
    expect(AuditEvent.find_by!(target: posting, action: "update").changes_made["company_id"])
      .to eq([ aggregator.id, posting.reload.company_id ])
  end

  it "refuses a move without a reason, writing nothing" do
    posting
    expect { move(reasoning: " ") }.to raise_error(ArgumentError, /reasoning/)
    expect(Company.where(name: "Acme")).to be_empty
  end

  it "refuses a move to the company it already belongs to" do
    expect { move(name: aggregator.name, domain: aggregator.domain) }.to raise_error(ArgumentError, /already belongs/)
  end
end
