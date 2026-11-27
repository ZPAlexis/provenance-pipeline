require "rails_helper"

# The careers pages a free check left unread (4f): each tracked company's latest read of its list, and the pages after
# it in that run, that need reading; oldest first.
RSpec.describe Verifier::PagesToRead do
  let!(:acme) { create(:company, :resolved, name: "Acme", domain: "acme.example") }

  def check(company, run_id, at, url: company.careers_page_url, reason: nil, outcome: reason ? "error" : "ok")
    create(:page_check, company: company, purpose: "verification", step: nil, run_id: run_id, url: url, outcome: outcome,
                        reason: reason, read_via: reason ? "render" : "render+llm", checked_at: at)
  end

  it "lists what each company's latest read left unread, its next pages too, oldest first" do
    contoso = create(:company, :resolved, name: "Contoso", domain: "contoso.example")
    check(acme, "run-1", 2.days.ago, reason: "needs_reading")
    check(contoso, "run-2", 1.day.ago)
    check(contoso, "run-2", 1.day.ago + 1, url: "#{contoso.careers_page_url}?page=2", reason: "needs_reading")

    pages = described_class.list

    expect(pages.map { |page| [ page.company.name, page.url ] }).to eq([ [ "Acme", acme.careers_page_url ],
                                                                        [ "Contoso", "#{contoso.careers_page_url}?page=2" ] ])
    expect(pages.first.since).to be_within(1.second).of(2.days.ago)
  end

  it "forgets a page once a later check read the list, and never lists a company read through a free board, nor one no longer tracked" do
    check(acme, "run-1", 2.days.ago, reason: "needs_reading")
    check(acme, "run-2", 1.day.ago)
    board = create(:company, :resolved, board_vendor: "greenhouse", board_token: "beta", board_overlap: 1.0,
                                        board_evidence: "Lists the roles.", board_confirmed_at: 3.days.ago)
    check(board, "run-3", 1.day.ago, reason: "needs_reading")
    archived = create(:company, :resolved, tracking: "dismissed")
    check(archived, "run-4", 1.day.ago, reason: "needs_reading")

    expect(described_class.list).to be_empty
  end

  it "counts what a run's results left unread" do
    results = [ { "checks" => [ { "reason" => "needs_reading" }, { "reason" => nil } ] }, { "checks" => [ { "reason" => "needs_reading" } ] } ]

    expect(described_class.left_by(results)).to eq(2)
    expect(described_class.left_by(nil)).to eq(0)
  end
end
