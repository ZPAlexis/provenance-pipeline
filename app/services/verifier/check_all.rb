module Verifier
  # "Check everything" (1.4): every watched company with a role on record, read
  # as verifier:verify reads it, its verdicts recorded under one credential for
  # the run, then its suggestions brought up to date. Shared by the dashboard
  # (in the background, CheckNowJob) and verifier:verify.
  module CheckAll
    # What a run would read, and the most it could cost, from the record: a page read
    # through its confirmed board is free; a page whose role links are unchanged
    # reuses its earlier read for nothing; any other costs what it cost when last
    # read in full, or an average read when it never was.
    Plan = Data.define(:targets, :via_board, :reusable, :ceiling) do
      def companies = targets.size

      def roles = targets.sum { |target| target[:postings].size }
    end

    Outcome = Struct.new(:summary, :tally, :cost_usd, :run_id, :stopped, :invalid, keyword_init: true) do
      def finished? = stopped.nil?

      def answer = nil # a role's answer: a run over everything has many, in its tally
    end

    SCOPES = CheckNow::CHECKING

    module_function

    def companies = Company.watched.where(id: Posting.not_dismissed.select(:company_id))

    def plan(list = companies.to_a)
      targets = list.map { |company| Targets.verify(company) }
      by_id = list.index_by(&:id)
      per_page = CheckNow.average_read
      paid = targets.reject { |target| target[:board] }
      Plan.new(targets: targets, via_board: targets.count { |target| target[:board] },
               reusable: paid.count { |target| target[:previous].any? },
               ceiling: paid.sum { |target| Targets.full_read_cost(by_id[target[:id]]) || per_page })
    end

    # Runs it for `check_run`, whose run id and size are kept from the start so
    # the page can show its progress. Backs up first: it writes many verdicts.
    def run!(check_run, worker: Worker.new(run_dir: Worker.dir_for("verify")))
      list = companies.to_a
      targets = plan(list).targets
      check_run.update!(run_id: worker.run_dir.basename.to_s, total: targets.size)
      DatabaseBackup.call
      tally = Hash.new(0)
      invalid = []
      run = Authority.run(Ingest::ACTOR, scopes: SCOPES, purpose: "check everything", ttl: Authority::BATCH,
                                         issued_by: check_run.requested_by) do
        worker.run(targets, command: "verify").tap { |done| record(done.results, done.id, tally, invalid) }
      end
      refresh = Suggestions.refresh!(list) if SearchProfile.current
      Outcome.new(summary: summary(run, tally, invalid, refresh), tally: tally.to_h, cost_usd: cost(run.results),
                  run_id: run.id, stopped: run.stopped, invalid: invalid)
    end

    # Each result through the one write path; one that breaks the contract is set aside and said.
    def record(results, run_id, tally, invalid)
      ingest = Ingest.new(run_id: run_id)
      results.each do |result|
        ingest.verification(result).each { |what, count| tally[what] += count }
      rescue Ingest::InvalidResult => e
        invalid << e.message
      end
    end

    def summary(run, tally, invalid, refresh)
      count = run.results.size - invalid.size
      read = "#{count} #{'company'.pluralize(count)} read#{" (stopped: #{run.stopped})" if run.stopped}."
      verdicts = "Verdicts: #{tally[:written]} changed, #{tally[:unchanged]} confirmed, " \
                 "#{tally[:inconclusive]} without an answer."
      contract = ("#{invalid.size} not recorded: they break the result contract." if invalid.any?)
      [ read, verdicts, contract, refresh&.summary ].compact.join(" ")
    end

    def cost(results)
      results.sum do |result|
        Array(result["checks"]).sum { |check| check.dig("llm", "cost_usd").to_f } + result.dig("match_llm", "cost_usd").to_f
      end
    end
  end
end
