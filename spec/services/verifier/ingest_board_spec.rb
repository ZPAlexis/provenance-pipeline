require "rails_helper"

RSpec.describe Verifier::Ingest, "#board" do
  subject(:ingest) { described_class.new(run_id: "20261002T180000Z-find_boards") }

  let(:company) { create(:company, :resolved, name: "Acme", domain: "acme.example") }

  def result(outcome = "adopted", **overrides)
    { "kind" => "board", "target_id" => company.id, "outcome" => outcome,
      "board" => { "vendor" => "greenhouse", "board" => "acme" }, "page_roles" => 40, "board_roles" => 44,
      "overlap" => 0.975, "owner" => "confirmed",
      "evidence" => "greenhouse/acme lists 98% of the 40 roles the page showed, by the same title (44 roles on the board); " \
                    "the vendor records the same company name." }.merge(overrides.stringify_keys)
  end

  it "records an adopted board on the company, audited as the verifier, keeping the page on record" do
    expect(ingest.board(result)).to eq("adopted")

    expect(company.reload).to have_attributes(board_vendor: "greenhouse", board_token: "acme", board_overlap: 0.975,
                                              careers_page_url: "https://acme.example/careers")
    expect(company.board_in_use).to eq(vendor: "greenhouse", board: "acme")
    event = company.audit_events.sole
    expect(event).to have_attributes(actor: "agent:verifier", model_version: nil)
    expect(event.changes_made.keys).to include("board_vendor", "board_token", "board_overlap", "board_evidence")
    expect(event.reasoning).to include("verification reads it in place of the page", "lists 98% of the 40 roles",
                                       "Run 20261002T180000Z-find_boards.")
  end

  it "refreshes a board found again quietly, as a confirmed verdict is" do
    ingest.board(result)
    company.update_columns(board_confirmed_at: 20.days.ago)

    expect { ingest.board(result(overlap: 0.95)) }.not_to change(AuditEvent, :count)
    expect(company.reload).to have_attributes(board_overlap: 0.95)
    expect(company.board_confirmed_at).to be_within(1.minute).of(Time.current)
  end

  it "drops a board in use that no longer lists the page's roles, so the page is read again" do
    ingest.board(result)

    ingest.board(result("rejected", overlap: 0.4, evidence: "greenhouse/acme lists 40% of the 40 roles the page showed."))

    expect(company.reload).to have_attributes(board_vendor: nil, board_token: nil, board_confirmed_at: nil)
    expect(company.audit_events.order(:occurred_at).last.reasoning)
      .to include("The greenhouse/acme board no longer lists the watched page's roles", "lists 40%")
  end

  it "drops a board in use that is gone" do
    ingest.board(result)

    ingest.board(result("none", board: nil, overlap: 0.0, evidence: nil, reason: "no_board_found"))

    expect(company.reload.board_vendor).to be_nil
    expect(company.audit_events.order(:occurred_at).last.reasoning).to include("No board was found.")
  end

  it "writes nothing for a company with no board when none is adopted" do
    expect { ingest.board(result("rejected", overlap: 0.0)) }.not_to change(AuditEvent, :count)
    expect { ingest.board(result("none", board: nil, reason: "no_board_found")) }.not_to change(AuditEvent, :count)
    expect { ingest.board(result("error", board: nil, reason: "unexpected:HTTPError")) }.not_to change(AuditEvent, :count)
  end

  # The rule that lets a board be read without a human: checked at the write path too.
  it "refuses a board adopted on too little overlap, writing nothing" do
    expect { ingest.board(result(overlap: 0.8)) }
      .to raise_error(Verifier::Ingest::InvalidResult, /adopted with only 80% of the page's roles/)
    expect(company.reload.board_vendor).to be_nil
  end

  it "refuses a result for no known company" do
    expect { ingest.board(result(target_id: SecureRandom.uuid)) }.to raise_error(Verifier::Ingest::InvalidResult, /no such company/)
  end
end
