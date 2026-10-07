module Verifier
  # A check the operator asks for: one role (its own page first, then its
  # company's careers page) or one company (its whole careers page). Shared by
  # verifier:check and the pages' "Check now". Its result goes through the one
  # write path, as agent:verifier, like any other check.
  module CheckNow
    Outcome = Struct.new(:answer, :summary, :tally, :cost_usd, :run_id, :run_dir, :stopped, keyword_init: true) do
      def finished? = stopped.nil?
    end

    module_function

    # Why a role or company cannot be checked now; nil when it can.
    def refusal(record)
      company = record.is_a?(Posting) ? record.company : record
      if record.is_a?(Posting) && record.tracking == "dismissed"
        "#{record.role_title} is dismissed: track it again to check it."
      elsif company.resolution_status != "resolved"
        "#{company.name} has no watched careers page yet."
      elsif company.kind == "aggregator"
        "#{company.name} is an aggregator: its postings belong to other employers."
      end
    end

    # What a check could cost at most: what the company's careers page cost when
    # last read in full (a role's check reads it when its own page cannot answer),
    # or an average page read for a company never verified. A free board costs nothing.
    def ceiling(record)
      company = record.is_a?(Posting) ? record.company : record
      return 0.0 if company.board_in_use

      Targets.full_read_cost(company) || LlmCall.where(purpose: "extract").average(:cost_usd).to_f
    end

    def role(posting, worker: Worker.new(run_dir: Worker.dir_for("check")))
      run = worker.run([ Targets.check(posting) ], command: "check")
      record(run) do |result, verdicts|
        verdict = verdicts.first
        [ verdict&.dig("verdict"), verdict ? verdict["reasoning"] : "The check failed (#{result['reason']}); nothing was written." ]
      end
    end

    def company(company, worker: Worker.new(run_dir: Worker.dir_for("verify")))
      run = worker.run([ Targets.verify(company) ], command: "verify")
      record(run) do |result, verdicts|
        found = verdicts.map { |v| v["verdict"] || "inconclusive" }.tally
        read = result["outcome"] == "ok" ? "#{result['listing_count']} roles read#{', the whole list' if result['complete']}" : "Not read (#{result['reason']})"
        roles = found.map { |state, count| "#{count} #{Posting::ANSWER_LABELS.fetch(state, 'no answer').downcase}" }
        [ nil, [ "#{read}.", roles.any? ? "Roles: #{roles.join(', ')}." : "No roles to check." ].join(" ") ]
      end
    end

    # Records the run's one result through the write path; the block turns it into an answer and a summary.
    def record(run)
      result = run.results.first
      unless result
        return Outcome.new(summary: "Stopped before a result: #{run.stopped || 'no result written'}.", tally: {},
                           cost_usd: 0.0, run_id: run.id, run_dir: run.dir, stopped: run.stopped || "no result")
      end

      tally = Ingest.new(run_id: run.id).verification(result)
      verdicts = Array(result["verdicts"])
      answer, summary = yield(result, verdicts)
      Outcome.new(answer: answer, summary: summary, tally: tally.to_h, cost_usd: cost(result), run_id: run.id,
                  run_dir: run.dir, stopped: run.stopped)
    end

    def cost(result)
      Array(result["checks"]).sum { |check| check.dig("llm", "cost_usd").to_f } + result.dig("match_llm", "cost_usd").to_f
    end
  end
end
