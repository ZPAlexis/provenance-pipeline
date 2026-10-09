module Verifier
  # A check the operator asks for: one role (its own page first, then its
  # company's careers page) or one company (its whole careers page). Shared by
  # verifier:check and the pages' "Check now". Its result goes through the one
  # write path, as agent:verifier, like any other check. A company with no
  # watched page yet (one just added, say) has it found first, as
  # verifier:resolve finds it, the page on record tried first.
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
      elsif company.kind == "aggregator"
        "#{company.name} is an aggregator: its postings belong to other employers."
      elsif company.resolution_status == "candidate"
        "#{company.name} has a careers page waiting for you: confirm, reject, or set it first."
      elsif Resolution.anonymised?(company)
        "#{company.name} is not a company: the employer is withheld."
      elsif record.is_a?(Posting) && company.resolution_status != "resolved"
        "#{company.name} has no watched careers page yet: check the company first."
      end
    end

    # What a check could cost at most: what the company's careers page cost when
    # last read in full (a role's check reads it when its own page cannot answer),
    # or an average page read for a company never verified, plus what finding its
    # page costs on average when it has none yet. A free board costs nothing.
    def ceiling(record)
      company = record.is_a?(Posting) ? record.company : record
      return 0.0 if company.board_in_use

      read = Targets.full_read_cost(company) || LlmCall.where(purpose: "extract").average(:cost_usd).to_f
      company.resolution_status == "resolved" ? read : read + finding_cost
    end

    # What finding a careers page has cost per company, on average, from the record.
    def finding_cost
      spent = LlmCall.joins(:page_check).where(page_checks: { purpose: "resolution" }).sum(:cost_usd).to_f
      spent / [ PageCheck.where(purpose: "resolution").distinct.count(:company_id), 1 ].max
    end

    def role(posting, worker: Worker.new(run_dir: Worker.dir_for("check")))
      run = worker.run([ Targets.check(posting) ], command: "check")
      record(run) do |result, verdicts|
        verdict = verdicts.first
        [ verdict&.dig("verdict"), verdict ? verdict["reasoning"] : "The check failed (#{result['reason']}); nothing was written." ]
      end
    end

    def company(company, worker: Worker.new(run_dir: Worker.dir_for("verify")), finder: nil)
      unless company.resolution_status == "resolved"
        found = find_page(company, finder || Worker.new(run_dir: Worker.dir_for("resolve")))
        return found unless company.resolution_status == "resolved"
      end

      outcome = read_list(company, worker)
      return outcome unless found

      outcome.summary = "#{found.summary} #{outcome.summary}"
      outcome.cost_usd += found.cost_usd
      outcome
    end

    # A company's careers page found and recorded as verifier:resolve records it,
    # as the verifier. A low-confidence find waits for the operator; nothing found says why.
    def find_page(company, finder)
      run = finder.run(Resolution.targets([ company ]), command: "resolve")
      result = run.results.first
      unless result
        return Outcome.new(summary: "Stopped before its careers page was found: #{run.stopped || 'no result written'}.",
                           tally: {}, cost_usd: 0.0, run_id: run.id, run_dir: run.dir, stopped: run.stopped || "no result")
      end

      Ingest.new(run_id: run.id).resolution(result)
      company.reload
      summary =
        case company.resolution_status
        when "resolved"
          "Careers page found: #{company.careers_page_url} (#{company.resolution_method}, #{company.resolution_confidence})."
        when "candidate"
          "A careers page was found, but only at low confidence: #{company.resolution_candidate_url}. " \
            "Confirm it, reject it, or set the right one on this page."
        else
          "No careers page found (#{company.resolution_failure || result['reason']}). Set it by hand on this page if you know it."
        end
      Outcome.new(summary: summary, tally: {}, cost_usd: cost(result), run_id: run.id, run_dir: run.dir, stopped: run.stopped)
    end

    def read_list(company, worker)
      run = worker.run([ Targets.verify(company) ], command: "verify")
      record(run) do |result, verdicts|
        found = verdicts.map { |v| v["verdict"] || "inconclusive" }.tally
        read = result["outcome"] == "ok" ? "#{result['listing_count']} roles read#{', the whole list' if result['complete']}" : "Not read (#{result['reason']})"
        roles = found.map { |state, count| "#{count} #{Posting::ANSWER_LABELS.fetch(state, 'no answer').downcase}" }
        [ nil, [ "#{read}.", roles.any? ? "Roles on record: #{roles.join(', ')}." : "No role on record here yet." ].join(" ") ]
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
      summary = [ summary, suggestions_after(result["target_id"], always: verdicts.empty?) ].compact.join(" ")
      Outcome.new(answer: answer, summary: summary, tally: tally.to_h, cost_usd: cost(result), run_id: run.id,
                  run_dir: run.dir, stopped: run.stopped)
    end

    # A check may read the company's list anew: its suggestions are brought up to
    # date, at no cost. Said when something changed, or `always` (a company with
    # no role on record, where it is the only news); a failure here never fails
    # the check, whose verdicts are already written.
    def suggestions_after(company_id, always: false)
      company = Company.find_by(id: company_id) or return
      refresh = Suggestions.refresh!([ company ])
      return refresh.summary if (refresh.created + refresh.updated + refresh.withdrawn).positive? || (refresh.run_id && refresh.problems.any?)

      "Suggestions: none of its roles fits your search profile." if always && refresh.run_id
    rescue Worker::Error, ActiveRecord::ActiveRecordError => e
      "Suggestions could not be brought up to date: #{e.message}"
    end

    def cost(result)
      Array(result["checks"]).sum { |check| check.dig("llm", "cost_usd").to_f } + result.dig("match_llm", "cost_usd").to_f
    end
  end
end
