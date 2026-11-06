module Verifier
  # The read a proposed company gets when it is tracked (4b), by the operator or by their own client on their word:
  # at once, and always free. The worker runs with no API key at all, so nothing it does can reach the LLM: it reads
  # the board the proposal named through the board's own API, and says whose it is as the resolver says of a board it
  # guessed (the vendor records the same company name, or the board's page links to the company's site). The careers
  # page stays the verifier's write, under its own credential; the client's link is only where it looks.
  #
  # The company's own board: watched (medium confidence), and its roles read, so finding roles sees them, and the
  # suggester weighs them. Nothing ties it to the company: held for the operator to confirm, as a low-confidence find
  # is. Another company's board, or none: nothing set, for Check now to find its page, asking first what that costs.
  # No verdict is ever written here: the read carries no role, and a role's first answer is its own first check.
  module BoardRead
    module_function

    # The board to read: the one the proposal's own free read saw, unless that was another company's, else a known
    # board among the links the client gave. Nil when there is none.
    def link(company)
      proposal = company.proposal or return
      seen = proposal["seen"] || {}
      (seen["board"] unless seen["owner"] == "another company's") || Proposals.board_url([ proposal["link"], *proposal["links"] ])
    end

    # Starts the read once the tracking that called it commits: in the background, on its company's check run (one at
    # a time per company), or at once where jobs run inline (a command). Nothing is started when the tracking rolls
    # back, or when the proposal names no known board.
    def after_tracking(company, requested_by:)
      return unless link(company)

      ActiveRecord.after_all_transactions_commit { CheckRun.start_board!(company, requested_by: requested_by) }
    end

    def run!(company, finder: nil, worker: nil)
      finder ||= Worker.new(run_dir: Worker.dir_for("own_board"), free: true)
      worker ||= Worker.new(run_dir: Worker.dir_for("verify"), free: true)
      raise ArgumentError, "the read on tracking a proposal runs only with no API key" unless finder.free? && worker.free?

      found = find_page(company, finder) unless company.resolution_status == "resolved"
      return found if found && company.resolution_status != "resolved"

      read = read_roles(company, worker)
      read.summary = "#{found.summary} #{read.summary}" if found
      read
    end

    def find_page(company, finder)
      url = link(company) or
        return CheckNow::Outcome.new(summary: "No known board to read: Check now finds its careers page, asking first what it costs.",
                                     tally: {}, cost_usd: 0.0)

      run, result = Authority.run(Ingest::ACTOR, scopes: CheckNow::FINDING, purpose: "tracked: #{company.name}'s board, read free") do
        run = finder.run([ { id: company.id, label: company.name, domain: company.domain, name: company.name, url: url } ],
                         command: "own_board")
        result = run.results.first
        Ingest.new(run_id: run.id).own_board(result) if result
        [ run, result ]
      end
      unless result
        return CheckNow::Outcome.new(summary: "Stopped before its board was read: #{run.stopped || 'no result written'}.", tally: {},
                                     cost_usd: 0.0, run_id: run.id, run_dir: run.dir, stopped: run.stopped || "no result")
      end

      company.reload
      summary =
        case company.resolution_status
        when "resolved" then "Its board is its own: watched at #{company.careers_page_url}."
        when "candidate"
          "A board was read, but nothing ties it to #{company.name}: #{company.resolution_candidate_url} waits for you to confirm or reject it."
        else
          "The board it was proposed with isn't its own (#{result['evidence'] || result['reason']}): Check now finds its careers " \
            "page, asking first what it costs."
        end
      CheckNow::Outcome.new(summary: summary, tally: {}, cost_usd: 0.0, run_id: run.id, run_dir: run.dir, stopped: run.stopped)
    end

    # Its roles read through the board's API, carrying no role, so no verdict is written; the suggester weighs them after.
    def read_roles(company, worker)
      start = -> { worker.run([ Targets.verify(company, postings: Posting.none) ], command: "verify", flags: [ "--no-llm" ]) }
      CheckNow.record(start, purpose: "tracked: #{company.name}'s roles, read free") do |result, _verdicts|
        read = result["outcome"] == "ok" ? "#{result['listing_count']} roles read#{', the whole list' if result['complete']}." : "Its roles were not read (#{result['reason']})."
        [ nil, read ]
      end
    end

    private_class_method :find_page, :read_roles
  end
end
