require "rails_helper"

RSpec.describe Verifier::CheckNow do
  let(:company) { create(:company, :resolved, name: "Acme", domain: "acme.example") }
  let(:role) { create(:posting, company: company, role_title: "RevOps Engineer") }

  # Stands in for Verifier::Worker: records what it was asked to run, and hands back the results given.
  let(:worker_class) do
    Class.new do
      attr_reader :asked

      def initialize(results, stopped: nil)
        @results, @stopped = results, stopped
      end

      def run(targets, command:)
        @asked = { targets: targets, command: command }
        Verifier::Worker::Run.new(dir: Pathname.new("tmp/verifier/20261007T120000Z-#{command}"), results: @results, stopped: @stopped)
      end
    end
  end

  def verification(verdicts:, complete: false, listing_count: nil, checks: nil)
    { "kind" => "verification", "target_id" => company.id, "url" => company.careers_page_url, "outcome" => "ok",
      "complete" => complete, "listing_count" => listing_count, "verdicts" => verdicts,
      "checks" => checks || [ { "url" => "https://acme.example/jobs/1", "checked_at" => "2026-10-07T12:00:00+00:00",
                                "outcome" => "ok", "method" => "render", "listings" => [] } ] }
  end

  def verdict(value, method: "posting_page", reasoning: "Its own page is up and shows the role (https://acme.example/jobs/1).")
    { "posting_id" => role.id, "verdict" => value, "method" => method, "reasoning" => reasoning,
      "listing" => ({ "title" => "RevOps Engineer", "url" => "https://acme.example/jobs/1" } if value == "verified_live") }
  end

  describe ".role" do
    it "checks one role, records its verdict through the write path, and says what it found" do
      worker = worker_class.new([ verification(verdicts: [ verdict("verified_live") ]) ])

      outcome = described_class.role(role, worker: worker)

      expect(worker.asked[:command]).to eq("check")
      expect(worker.asked[:targets].sole[:postings].pluck(:id)).to eq([ role.id ])
      expect(outcome).to have_attributes(answer: "verified_live", tally: { written: 1 }, cost_usd: 0.0,
                                         run_id: "20261007T120000Z-check", summary: /Its own page is up/)
      expect(outcome).to be_finished
      expect(role.reload).to have_attributes(verification_state: "verified_live", job_url: "https://acme.example/jobs/1")
    end

    it "has no answer when the check could not confirm, and writes no verdict" do
      inconclusive = verdict(nil, method: "none", reasoning: "Its own page is gone; the careers page shows only part of its list.")
      outcome = described_class.role(role, worker: worker_class.new([ verification(verdicts: [ inconclusive ]) ]))

      expect(outcome).to have_attributes(answer: nil, tally: { inconclusive: 1 }, summary: /only part of its list/)
      expect(role.reload.verification_state).to eq("pending")
    end

    it "says why when the run stopped before a result" do
      outcome = described_class.role(role, worker: worker_class.new([], stopped: "API credit exhausted"))

      expect(outcome).not_to be_finished
      expect(outcome.summary).to eq("Stopped before a result: API credit exhausted.")
    end
  end

  describe ".company" do
    it "checks a company's careers page in full and sums up its roles" do
      page = { "url" => company.careers_page_url, "checked_at" => "2026-10-07T12:00:00+00:00", "outcome" => "ok",
               "method" => "ats_api:lever", "listing_count" => 12, "listings" => [ { "title" => "RevOps Engineer" } ] }
      live = verdict("verified_live", method: "exact", reasoning: 'The page lists "RevOps Engineer".')
      worker = worker_class.new([ verification(verdicts: [ live ], complete: true, listing_count: 12, checks: [ page ]) ])

      outcome = described_class.company(company, worker: worker)

      expect(worker.asked[:command]).to eq("verify")
      expect(outcome).to have_attributes(answer: nil, summary: "12 roles read, the whole list. Roles: 1 still listed.")
    end
  end

  describe ".refusal" do
    it "refuses a dismissed role, a company with no watched page, and an aggregator" do
      expect(described_class.refusal(role)).to be_nil
      expect(described_class.refusal(company)).to be_nil

      role.update!(tracking: "dismissed")
      expect(described_class.refusal(role)).to match(/dismissed/)
      expect(described_class.refusal(create(:company))).to match(/no watched careers page/)
      expect(described_class.refusal(create(:company, :resolved, kind: "aggregator"))).to match(/aggregator/)
    end
  end

  describe ".ceiling" do
    it "is nothing through a free board, what the page cost when last read in full, or an average read" do
      create(:llm_call, cost_usd: 0.02)
      expect(described_class.ceiling(role)).to be_within(1e-9).of(0.02) # never verified: the average read

      check = create(:page_check, company: company, purpose: "verification", run_id: "r1")
      create(:llm_call, page_check: check, cost_usd: 0.07)
      expect(described_class.ceiling(company)).to be_within(1e-9).of(0.07)

      company.update!(board_vendor: "ashby", board_token: "acme", board_overlap: 0.95, board_evidence: "Lists the roles.",
                      board_confirmed_at: 1.day.ago)
      expect(described_class.ceiling(role)).to eq(0.0)
    end
  end
end
