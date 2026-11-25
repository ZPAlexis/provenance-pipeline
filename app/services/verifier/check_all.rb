module Verifier
  # "Check all tracked companies" (1.4's "check everything"; since 4e every tracked
  # company, not only those with a role on record): each one's careers page read
  # as verifier:verify reads it, the verdicts on its roles recorded under one
  # credential for the run, then its suggestions brought up to date from the lists
  # just read. Shared by the Roles page (in the background, CheckNowJob) and
  # verifier:verify.
  module CheckAll
    # What a run would read, and the most it could cost, from the record: a page read
    # through its confirmed board is free; a page whose role links are unchanged
    # reuses its earlier read for nothing; any other costs what it cost when last
    # read in full, or an average read when it never was.
    Plan = Data.define(:targets, :via_board, :reusable, :ceiling, :unread) do
      def companies = targets.size

      def roles = targets.sum { |target| target[:postings].size }

      # Read for new roles alone (4e): no role of theirs on record yet.
      def without_roles = targets.count { |target| target[:postings].empty? }

      # What it would cost is known ("at most") only when every page it pays to read was read in full before; one never
      # read is priced at an average list, and a long list costs more ("about").
      def known_cost? = unread.zero?
    end

    Outcome =Struct.new(:summary, :tally, :cost_usd, :run_id, :stopped, :invalid, keyword_init: true) do
      def finished? = stopped.nil?

      def answer = nil # a role's answer: a run over everything has many, in its tally
    end

    SCOPES = CheckNow::CHECKING

    module_function

    # How old the tracked companies' lists are (4e), as the dashboard and the Roles page say it: how many were last read
    # whole longer ago than `stale_after`, how many never, and the oldest read. The AI assistant's role search reads the
    # lists as they were last read, so this is how current what it finds is.
    Ages = Data.define(:companies, :stale, :never, :oldest)

    # Every tracked company with a careers page to read (since 4e, a role on record or not: a check finds new ones).
    def companies = Company.watched

    def ages(stale_after: Overview::STALE_AFTER)
      ids = companies.pluck(:id)
      last = WatchList.last_checked(ids)
      times = ids.map { |id| last[id] }
      Ages.new(companies: ids.size, stale: times.count { |time| time&.before?(stale_after.ago) }, never: times.count(&:nil?),
               oldest: times.compact.min)
    end

    def plan(list = companies.to_a)
      targets = list.map { |company| Targets.verify(company) }
      by_id = list.index_by(&:id)
      per_page = CheckNow.average_full_read
      paid = targets.reject { |target| target[:board] }
      known = paid.to_h { |target| [ target[:id], Targets.full_read_cost(by_id[target[:id]]) ] }
      Plan.new(targets: targets, via_board: targets.count { |target| target[:board] },
               reusable: paid.count { |target| target[:previous].any? },
               ceiling: known.values.sum { |cost| cost || per_page }, unread: known.values.count(&:nil?))
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
      run = Authority.run(Ingest::ACTOR, scopes: SCOPES, purpose: "check all tracked companies", ttl: Authority::BATCH,
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
