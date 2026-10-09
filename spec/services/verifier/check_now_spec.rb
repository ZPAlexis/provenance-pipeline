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
      expect(outcome).to have_attributes(answer: nil, summary: "12 roles read, the whole list. Roles on record: 1 still listed.")
    end

    it "brings the company's suggestions up to date after its check, and says so when they changed" do
      refreshed = Verifier::Suggestions::Refresh.new(created: 2, updated: 0, withdrawn: 0, problems: [], run_id: "r1")
      allow(Verifier::Suggestions).to receive(:refresh!).and_return(refreshed)
      worker = worker_class.new([ verification(verdicts: [], complete: true, listing_count: 0) ])

      outcome = described_class.company(company, worker: worker)

      expect(Verifier::Suggestions).to have_received(:refresh!).with([ company ])
      expect(outcome.summary).to end_with("Suggestions: 2 new.")
    end

    # A company with no role on record (one just added): what the profile found is the only news.
    it "says when none of a company's roles fits the profile, when it has no role on record" do
      nothing = Verifier::Suggestions::Refresh.new(created: 0, updated: 0, withdrawn: 0, problems: [], run_id: "r1")
      allow(Verifier::Suggestions).to receive(:refresh!).and_return(nothing)
      worker = worker_class.new([ verification(verdicts: [], complete: true, listing_count: 134) ])

      outcome = described_class.company(company, worker: worker)

      expect(outcome.summary).to eq("134 roles read, the whole list. No role on record here yet. " \
                                    "Suggestions: none of its roles fits your search profile.")
    end

    it "never fails a check over its suggestions, whose verdicts are already written" do
      allow(Verifier::Suggestions).to receive(:refresh!).and_raise(Verifier::Worker::Error, "the verification worker exited with status 1")
      worker = worker_class.new([ verification(verdicts: [], complete: true, listing_count: 0) ])

      outcome = described_class.company(company, worker: worker)

      expect(outcome).to be_finished
      expect(outcome.summary).to end_with("Suggestions could not be brought up to date: the verification worker exited with status 1")
    end
  end

  describe ".refusal" do
    it "refuses a dismissed role, an aggregator, a page waiting for the operator, and a withheld employer" do
      expect(described_class.refusal(role)).to be_nil
      expect(described_class.refusal(company)).to be_nil
      expect(described_class.refusal(create(:company))).to be_nil # its careers page is found first

      role.update!(tracking: "dismissed")
      expect(described_class.refusal(role)).to match(/dismissed/)
      expect(described_class.refusal(create(:company, :resolved, kind: "aggregator"))).to match(/aggregator/)
      expect(described_class.refusal(create(:company, :resolution_candidate))).to match(/waiting for you/)
      expect(described_class.refusal(create(:company, name: "Confidencial"))).to match(/employer is withheld/)
      expect(described_class.refusal(create(:posting, company: create(:company)))).to be_nil # its company's page found first
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

    it "adds one read for a role to be named by its own page on the company's site, never on an ATS" do
      create(:llm_call, cost_usd: 0.02)
      check = create(:page_check, company: company, purpose: "verification", run_id: "r1")
      create(:llm_call, page_check: check, cost_usd: 0.07)

      untitled = create(:posting, company: company, role_title: Posting::TITLE_PENDING, job_url: "https://acme.example/jobs/7")
      expect(described_class.ceiling(untitled)).to be_within(1e-9).of(0.07 + 0.045) # the page, and one average read
      untitled.update!(job_url: "https://jobs.lever.co/acme/0f1e")
      expect(described_class.ceiling(untitled)).to be_within(1e-9).of(0.07) # its board's listing names it, free
    end

    it "adds what finding a careers page has cost per company when it has none yet" do
      create(:llm_call, cost_usd: 0.02) # the average read, made while finding a page (the factory's check)
      found = create(:page_check, company: create(:company), purpose: "resolution")
      create(:llm_call, page_check: found, purpose: "resolve", cost_usd: 0.01)

      # The average read, plus finding: $0.03 spent across two companies' pages.
      expect(described_class.ceiling(create(:company))).to be_within(1e-9).of(0.02 + 0.015)
    end
  end

  describe ".company, for a company with no watched page" do
    let(:added) { create(:company, name: "Beta", domain: "beta.example", careers_page_url: "https://beta.example/jobs") }

    def found(outcome, **fields)
      page = { "url" => "https://beta.example/jobs", "final_url" => "https://beta.example/jobs", "step" => "imported",
               "checked_at" => "2026-10-09T12:00:00+00:00", "outcome" => "ok", "method" => "render", "listings" => [] }
      { "kind" => "resolution", "target_id" => added.id, "outcome" => outcome, "checks" => [ page ] }.merge(fields.stringify_keys)
    end

    it "finds its careers page first, the page on record tried first, then reads its roles" do
      finder = worker_class.new([ found("resolved", careers_page_url: "https://beta.example/jobs", method: "imported", confidence: "high") ])
      reader = worker_class.new([ verification(verdicts: [], complete: true, listing_count: 4).merge("target_id" => added.id, "url" => "https://beta.example/jobs") ])

      outcome = described_class.company(added, worker: reader, finder: finder)

      expect(finder.asked).to include(command: "resolve", targets: [ include(id: added.id, known_url: "https://beta.example/jobs") ])
      expect(reader.asked[:command]).to eq("verify")
      expect(added.reload).to have_attributes(resolution_status: "resolved", resolution_method: "imported")
      expect(outcome.summary).to start_with("Careers page found: https://beta.example/jobs (imported, high). 4 roles read")
      expect(outcome.summary).to include("No role on record here yet.")
    end

    it "stops at a page found only at low confidence, for the operator to decide" do
      finder = worker_class.new([ found("candidate", careers_page_url: "https://beta.example/maybe", method: "llm_link", confidence: "low") ])
      reader = worker_class.new([])

      outcome = described_class.company(added, worker: reader, finder: finder)

      expect(reader.asked).to be_nil
      expect(added.reload.resolution_candidate_url).to eq("https://beta.example/maybe")
      expect(outcome).to be_finished
      expect(outcome.summary).to match(/only at low confidence: https:\/\/beta.example\/maybe\. Confirm it, reject it/)
    end

    it "says when no page was found" do
      outcome = described_class.company(added, worker: worker_class.new([]), finder: worker_class.new([ found("failed", failure: "not_found") ]))

      expect(outcome.summary).to eq("No careers page found (not_found). Set it by hand on the company's page if you know it.")
    end

    it "finds it first for a role's check too, then checks the role, its own page first" do
      posting = create(:posting, company: added, role_title: "Sales Engineer", job_url: "https://beta.example/jobs/7")
      finder = worker_class.new([ found("resolved", careers_page_url: "https://beta.example/jobs", method: "imported", confidence: "high") ])
      live = { "posting_id" => posting.id, "verdict" => "verified_live", "method" => "posting_page",
               "listing" => { "title" => "Sales Engineer", "url" => "https://beta.example/jobs/7" },
               "reasoning" => "Its own page is up and shows the role (https://beta.example/jobs/7)." }
      checker = worker_class.new([ verification(verdicts: [ live ]).merge("target_id" => added.id, "url" => "https://beta.example/jobs") ])

      outcome = described_class.role(posting, worker: checker, finder: finder)

      expect(checker.asked).to include(command: "check", targets: [ include(postings: [ include(id: posting.id) ]) ])
      expect(outcome.answer).to eq("verified_live")
      expect(outcome.summary).to start_with("Careers page found: https://beta.example/jobs (imported, high). Its own page is up")
    end
  end
end
