require "rails_helper"

RSpec.describe Verifier::CheckAll do
  let!(:company) { create(:company, :resolved, name: "Acme", domain: "acme.example") }
  let!(:role) { create(:posting, company: company, role_title: "RevOps Engineer") }

  # Stands in for Verifier::Worker: records what it was asked to run, and hands back the results given.
  let(:worker_class) do
    Class.new do
      attr_reader :asked, :run_dir

      def initialize(run_dir, results)
        @run_dir, @results = run_dir, results
      end

      def run(targets, command:)
        @asked = { targets: targets, command: command }
        Verifier::Worker::Run.new(dir: run_dir, results: @results, stopped: nil)
      end
    end
  end

  def verification(verdict)
    { "kind" => "verification", "target_id" => company.id, "url" => company.careers_page_url, "outcome" => "ok",
      "complete" => true, "listing_count" => 12, "verdicts" => [ verdict ],
      "checks" => [ { "url" => company.careers_page_url, "checked_at" => "2026-10-14T12:00:00+00:00", "outcome" => "ok",
                      "method" => "render+llm", "listings" => [] } ] }
  end

  describe ".plan" do
    it "reads every watched company with a role on record: free through a board, otherwise at most what its pages cost" do
      on_board = create(:company, :resolved, board_vendor: "greenhouse", board_token: "beta", board_overlap: 1.0,
                                             board_evidence: "Lists the roles.", board_confirmed_at: 1.day.ago)
      create(:posting, company: on_board)
      create(:company, :resolved) # no role on record: nothing to read
      read = create(:page_check, company: company, purpose: "verification", step: nil, url: company.careers_page_url)
      create(:llm_call, page_check: read, cost_usd: 0.02)

      expect(described_class.plan).to have_attributes(companies: 2, roles: 2, via_board: 1, reusable: 1, ceiling: 0.02)
    end
  end

  describe ".run!" do
    before { allow(DatabaseBackup).to receive(:call) }

    it "reads them all under one credential for the run, its size kept from the start, backed up first" do
      check_run = create(:check_run, kind: "all", company: nil)
      live = { "posting_id" => role.id, "verdict" => "verified_live", "method" => "exact", "reasoning" => "Listed.",
               "listing" => { "title" => "RevOps Engineer" } }
      worker = worker_class.new(Pathname.new("tmp/verifier/20261014T120000Z-verify"), [ verification(live) ])

      outcome = described_class.run!(check_run, worker: worker)

      expect(DatabaseBackup).to have_received(:call)
      expect(check_run.reload).to have_attributes(total: 1, run_id: "20261014T120000Z-verify")
      expect(worker.asked).to include(command: "verify")
      expect(outcome).to have_attributes(tally: { written: 1 }, stopped: nil,
                                         summary: "1 company read. Verdicts: 1 changed, 0 confirmed, 0 without an answer.")
      expect(role.reload.verification_state).to eq("verified_live")
      expect(AuditEvent.find_by!(target: role, action: "update").credential.reload).to have_attributes(
        purpose: "check everything", scopes: %w[postings:verify evidence:write], issued_by: "human:operator", status: "revoked"
      )
    end

    it "sets aside a result that breaks the contract, and says so" do
      worker = worker_class.new(Pathname.new("tmp/verifier/20261014T120000Z-verify"),
                                [ verification({ "posting_id" => role.id, "verdict" => "maybe" }) ])

      outcome = described_class.run!(create(:check_run, kind: "all", company: nil), worker: worker)

      expect(outcome.invalid.size).to eq(1)
      expect(outcome.summary).to start_with("0 companies read.").and(include("1 not recorded"))
    end
  end
end
