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
    # Since 4e, a tracked company with no role on record is read too: a check finds new roles there.
    it "reads every tracked company, a role on record or not: free through a board, otherwise at most what its pages cost" do
      on_board = create(:company, :resolved, board_vendor: "greenhouse", board_token: "beta", board_overlap: 1.0,
                                             board_evidence: "Lists the roles.", board_confirmed_at: 1.day.ago)
      create(:posting, company: on_board)
      create(:company, :resolved) # no role on record: read for new ones, at an average read's cost (never read)
      read = create(:page_check, company: company, purpose: "verification", step: nil, url: company.careers_page_url)
      create(:llm_call, page_check: read, cost_usd: 0.02)

      expect(described_class.plan).to have_attributes(companies: 3, roles: 2, without_roles: 1, via_board: 1, reusable: 1, ceiling: 0.04,
                                                      to_read: 2) # 4f: the pages a free check may leave for the AI assistant
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
        purpose: "check all tracked companies", scopes: %w[postings:verify evidence:write], issued_by: "human:operator", status: "revoked"
      )
    end

    # 4f: a free check calls no AI. A page that needs reading is left unread, no verdict written, and the run says so.
    it "runs a free check with a free worker, writing no verdict from a page left unread, and says how many it left" do
      check_run = create(:check_run, kind: "all", company: nil, request: { "mode" => "free" })
      unread = { "kind" => "verification", "target_id" => company.id, "url" => company.careers_page_url, "outcome" => "error",
                 "reason" => "needs_reading", "complete" => false, "verdicts" => [],
                 "checks" => [ { "url" => company.careers_page_url, "checked_at" => "2026-11-27T12:00:00+00:00", "outcome" => "error",
                                 "reason" => "needs_reading", "method" => "render" } ] }
      worker = worker_class.new(Pathname.new("tmp/verifier/20261127T120000Z-verify"), [ unread ])
      allow(Verifier::Worker).to receive(:new).and_return(worker)

      outcome = described_class.run!(check_run)

      expect(Verifier::Worker).to have_received(:new).with(hash_including(free: true))
      expect(outcome.summary).to eq("1 company checked. Verdicts: 0 changed, 0 confirmed, 0 without an answer. 1 page left unread: " \
                                    "it needs reading, which a free check leaves for your AI assistant.")
      expect(outcome.cost_usd).to eq(0)
      expect(role.reload.verification_state).to eq("pending")
      expect(company.page_checks.sole).to have_attributes(outcome: "error", reason: "needs_reading", read_via: "render")
      expect(Verifier::PagesToRead.list.map(&:url)).to eq([ company.careers_page_url ])
      expect(AgentCredential.sole).to have_attributes(purpose: "check all tracked companies (free)")
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
