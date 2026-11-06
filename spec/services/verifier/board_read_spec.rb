require "rails_helper"

# The read a proposed company gets when it is tracked (4b): at once, and always free. The worker runs with no API key;
# it reads the board the proposal named through the board's own API and says whose it is. The careers page is the
# verifier's write, under its own credential; no verdict is ever written here.
RSpec.describe Verifier::BoardRead do
  let(:company) do
    create(:company, :proposed, name: "Fabrikam", domain: "fabrikam.example", tracking: "tracked",
                                proposal: { "why" => "Sells to revenue teams.", "source" => "job_board_search", "link" => "https://fabrikam.example/careers",
                                            "seen" => { "board" => "https://jobs.ashbyhq.com/fabrikam", "roles" => 4, "owner" => "confirmed" } })
  end

  let(:worker_class) do
    Class.new do
      attr_reader :asked

      def initialize(results, free: true)
        @results, @free = results, free
      end

      def free? = @free

      def run(targets, command:, flags: [])
        @asked = { targets: targets, command: command, flags: flags }
        Verifier::Worker::Run.new(dir: Pathname.new("tmp/verifier/20261106T120000Z-#{command}"), results: @results, stopped: nil)
      end
    end
  end

  let(:nothing_new) { Verifier::Suggestions::Refresh.new(created: 0, updated: 0, withdrawn: 0, problems: [], run_id: "r1") }

  before { allow(Verifier::Suggestions).to receive(:refresh!).and_return(nothing_new) }

  def own_board(outcome:, confidence: nil, reason: nil, evidence: nil)
    { "kind" => "resolution", "target_id" => company.id, "outcome" => outcome, "method" => ("proposal" unless outcome == "failed"),
      "confidence" => confidence, "careers_page_url" => ("https://jobs.ashbyhq.com/fabrikam" unless outcome == "failed"),
      "failure" => ("not_found" if outcome == "failed"), "evidence" => evidence,
      "checks" => [ { "url" => "https://jobs.ashbyhq.com/fabrikam", "checked_at" => "2026-11-06T12:00:00+00:00", "outcome" => "ok",
                      "method" => "ats_api:ashby", "step" => "proposal", "listing_count" => 4, "reason" => reason,
                      "listings" => Array.new(4) { |n| { "title" => "Role #{n}" } } } ] }
  end

  def roles_read(listing_count: 4)
    { "kind" => "verification", "target_id" => company.id, "url" => "https://jobs.ashbyhq.com/fabrikam", "outcome" => "ok",
      "complete" => true, "listing_count" => listing_count, "verdicts" => [],
      "checks" => [ { "url" => "https://jobs.ashbyhq.com/fabrikam", "checked_at" => "2026-11-06T12:01:00+00:00", "outcome" => "ok",
                      "method" => "ats_api:ashby", "listings" => [] } ] }
  end

  it "watches the board when it is the company's own, reads its roles, and writes no verdict, all free" do
    role = create(:posting, company: company, role_title: "Solutions Engineer")
    finder = worker_class.new([ own_board(outcome: "resolved", confidence: "medium", evidence: "The ashby board records the same company name.") ])
    worker = worker_class.new([ roles_read ])

    outcome = described_class.run!(company, finder: finder, worker: worker)

    expect(finder.asked).to include(command: "own_board", targets: [ hash_including(url: "https://jobs.ashbyhq.com/fabrikam", domain: "fabrikam.example") ])
    # Its roles read with no role carried and no LLM to settle a near-miss: nothing to write a verdict on.
    expect(worker.asked).to include(command: "verify", flags: [ "--no-llm" ])
    expect(worker.asked[:targets].sole[:postings]).to eq([])
    expect(company.reload).to have_attributes(resolution_status: "resolved", resolution_method: "proposal", resolution_confidence: "medium",
                                              careers_page_url: "https://jobs.ashbyhq.com/fabrikam")
    expect(role.reload.verification_state).to eq("pending")
    expect(outcome).to have_attributes(cost_usd: 0.0, summary: "Its board is its own: watched at https://jobs.ashbyhq.com/fabrikam. " \
                                                               "4 roles read, the whole list. Suggestions: none of its roles fits your " \
                                                               "search profile.")
    expect(Verifier::Suggestions).to have_received(:refresh!).with([ company ])
    found = AuditEvent.where(target: company, actor: "agent:verifier").sole
    expect(found.reasoning).to start_with("Careers page found by proposal at medium confidence; 4 listings read there.")
    expect(found.credential.reload).to have_attributes(scopes: %w[companies:enrich evidence:write], purpose: "tracked: Fabrikam's board, read free")
    expect(company.page_checks.pluck(:purpose, :step)).to contain_exactly([ "resolution", "proposal" ], [ "verification", nil ])
  end

  it "holds a board nothing ties to the company for the operator to confirm, and reads no roles" do
    worker = worker_class.new([])

    outcome = described_class.run!(company, finder: worker_class.new([ own_board(outcome: "candidate", confidence: "low") ]), worker: worker)

    expect(company.reload).to have_attributes(resolution_status: "candidate", resolution_candidate_url: "https://jobs.ashbyhq.com/fabrikam")
    expect(company.review_items.open.pluck(:kind)).to eq([ "careers_page_candidate" ])
    expect(worker.asked).to be_nil
    expect(outcome.summary).to eq("A board was read, but nothing ties it to Fabrikam: https://jobs.ashbyhq.com/fabrikam waits for you to " \
                                  "confirm or reject it.")
  end

  it "sets nothing when the board is another company's, keeping what was read; and reads nothing with no board named" do
    another = own_board(outcome: "failed", reason: "board_of_another_company", evidence: "The board links to contoso.example: another company's board.")

    outcome = described_class.run!(company, finder: worker_class.new([ another ]), worker: worker_class.new([]))

    expect(company.reload.resolution_status).to be_nil
    expect(company.page_checks.where(purpose: "resolution").count).to eq(1)
    expect(outcome.summary).to start_with("The board it was proposed with isn't its own (The board links to contoso.example")

    company.update!(proposal: { "why" => "Sells to revenue teams.", "link" => "https://fabrikam.example/careers" })
    finder = worker_class.new([])
    expect(described_class.run!(company, finder: finder, worker: worker_class.new([])).summary).to start_with("No known board to read")
    expect(finder.asked).to be_nil
  end

  it "never runs with an API key" do
    expect { described_class.run!(company, finder: worker_class.new([], free: false), worker: worker_class.new([])) }
      .to raise_error(ArgumentError, "the read on tracking a proposal runs only with no API key")
  end

  describe "on tracking a proposal" do
    let!(:proposed) { create(:company, :proposed, name: "Contoso", domain: "contoso.example") }

    it "starts in the background once the tracking commits, as the request of whoever tracked it" do
      expect { Verifier::Tracking.track_company!(proposed, note: "It fits.") }.to have_enqueued_job(CheckNowJob)

      run = proposed.check_runs.sole
      expect(run).to have_attributes(kind: "company", request: { "read" => "board" }, ceiling_usd: 0, requested_by: "human:operator", status: "queued")
      expect(run).to be_board_read
      expect(AuditEvent.where(target: proposed).last.reasoning).to eq("Tracked by hand: proposed by the operator's own Claude client. It fits.")

      allow(DatabaseBackup).to receive(:daily)
      allow(described_class).to receive(:run!).and_return(Verifier::CheckNow::Outcome.new(summary: "Read.", tally: {}, cost_usd: 0.0))
      CheckNowJob.perform_now(run)
      expect(described_class).to have_received(:run!).with(proposed)
      expect(run.reload).to have_attributes(status: "done", summary: "Read.")
    end

    it "starts nothing when the tracking rolls back, or when the proposal names no known board" do
      ApplicationRecord.transaction do
        Verifier::Tracking.track_company!(proposed, note: "It fits.")
        raise ActiveRecord::Rollback
      end
      expect(CheckRun.count).to eq(0)

      proposed.reload.update!(proposal: { "why" => "Sells to revenue teams.", "link" => "https://contoso.example/careers" })
      expect { Verifier::Tracking.track_company!(proposed, note: "It fits.") }.not_to have_enqueued_job(CheckNowJob)
      expect(proposed.reload.tracking).to eq("tracked")
    end

    it "declines a proposal archived, for good" do
      Verifier::Tracking.dismiss_company!(proposed, note: "Not my market.")

      expect(proposed.reload.tracking).to eq("dismissed")
      expect(AuditEvent.where(target: proposed).last.reasoning)
        .to eq("Declined by hand: proposed by the operator's own Claude client, archived, and never proposed again. Not my market.")
    end
  end
end
