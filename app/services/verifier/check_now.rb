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

    # What each of its runs may write (1.3): finding a careers page, and checking roles against a list.
    FINDING = %w[companies:enrich evidence:write].freeze
    CHECKING = %w[postings:verify evidence:write].freeze

    module_function

    # Why a role or company cannot be checked now; nil when it can.
    def refusal(record)
      company = record.is_a?(Posting) ? record.company : record
      if record.is_a?(Posting) && record.tracking == "dismissed"
        "#{record.role_title} is archived: track it again to check it."
      elsif company.dismissed?
        "#{company.name} is archived: track it again to check it."
      elsif company.suggested?
        "#{company.name} was proposed to you, not tracked: track it to check it."
      elsif company.kind == "aggregator"
        "#{company.name} is an aggregator: its postings belong to other employers."
      elsif company.resolution_status == "candidate"
        "#{company.name} has a careers page waiting for you: confirm, reject, or set it first."
      elsif Resolution.anonymised?(company)
        "#{company.name} is not a company: the employer is withheld."
      end
    end

    # What a check could cost at most: what the company's careers page cost when
    # last read in full (a role's check reads it when its own page cannot answer),
    # or an average page read for a company never verified, plus what finding its
    # page costs on average when it has none yet. A free board costs nothing, nor (4e) a watched page on an ATS board,
    # read never before or not.
    def ceiling(record)
      company = record.is_a?(Posting) ? record.company : record
      # A role added without a title, on the company's own site, may need one LLM read of its page to be named.
      naming = record.is_a?(Posting) && record.title_pending? && !Capture.board(record.job_url.to_s) ? average_read : 0.0
      return naming if Targets.free_read?(company)

      read = Targets.full_read_cost(company) || average_full_read
      naming + (company.resolution_status == "resolved" ? read : read + finding_cost)
    end

    # Whether a check is sure to cost nothing (4e), so adding a role by link may start it unasked: its company's list
    # read free, or for nothing when last read in full, and the role named with no AI read (its title given, or its own
    # page on an ATS). An estimate of nothing, from a record with no reads to average, is not enough.
    def free?(record)
      return false if record.is_a?(Posting) && record.title_pending? && !Capture.board(record.job_url.to_s)

      known_cost?(record) && ceiling(record).zero?
    end

    # What one LLM read of one page costs on average: naming a role from its own page.
    def average_read = LlmCall.where(purpose: "extract").average(:cost_usd).to_f

    # What reading a careers page in full costs on average, every page of its list (4e): the estimate for a company
    # never read, in place of one call's average, which a check of all tracked companies found too low (2026-11-24: a
    # never-read list of many pages cost nine times one call). A list longer than most still costs more: hence "about".
    def average_full_read
      reads = LlmCall.joins(:page_check).where(purpose: "extract", page_checks: { purpose: "verification" })
                     .group("page_checks.company_id", "page_checks.run_id").sum(:cost_usd).values.map(&:to_f).select(&:positive?)
      reads.any? ? reads.sum / reads.size : average_read
    end

    # Whether what a check costs can be known from the record ("at most") or only estimated ("about"): known once its
    # company's page has been read in full, or is read through a free board.
    def known_cost?(record)
      company = record.is_a?(Posting) ? record.company : record
      Targets.free_read?(company) || Targets.full_read_cost(company).present?
    end

    # What finding a careers page has cost per company, on average, from the record.
    def finding_cost
      spent = LlmCall.joins(:page_check).where(page_checks: { purpose: "resolution" }).sum(:cost_usd).to_f
      spent / [ PageCheck.where(purpose: "resolution").distinct.count(:company_id), 1 ].max
    end

    # `issued_by` (4e step 12): who asked for the check, recorded on each credential its runs hold: the operator, or
    # their AI assistant (only ever for a free board read, on their word).
    def role(posting, worker: Worker.new(run_dir: Worker.dir_for("check")), finder: nil, issued_by: AuditEvent::OPERATOR)
      with_page(posting.company, finder, issued_by:) do
        start = -> { worker.run([ Targets.check(posting) ], command: "check") }
        record(start, purpose: "check now: #{posting.role_title} at #{posting.company.name}", issued_by:) do |result, verdicts|
          verdict = verdicts.first
          [ verdict&.dig("verdict"), verdict ? verdict["reasoning"] : "The check failed (#{result['reason']}); nothing was written." ]
        end
      end
    end

    def company(company, worker: Worker.new(run_dir: Worker.dir_for("verify")), finder: nil, issued_by: AuditEvent::OPERATOR)
      with_page(company, finder, issued_by:) { read_list(company, worker, issued_by:) }
    end

    # The check, once the company has a watched page: found first when it has none
    # (one just added, say), and the check said after what finding it found.
    def with_page(company, finder, issued_by: AuditEvent::OPERATOR)
      return yield if company.resolution_status == "resolved"

      found = find_page(company, finder || Worker.new(run_dir: Worker.dir_for("resolve")), issued_by:)
      return found unless company.resolution_status == "resolved"

      outcome = yield
      outcome.summary = "#{found.summary} #{outcome.summary}"
      outcome.cost_usd += found.cost_usd
      outcome
    end

    # A company's careers page found and recorded as verifier:resolve records it,
    # as the verifier, under a credential for this one run. A low-confidence find
    # waits for the operator; nothing found says why.
    def find_page(company, finder, issued_by: AuditEvent::OPERATOR)
      run, result = Authority.run(Ingest::ACTOR, scopes: FINDING, purpose: "check now: find #{company.name}'s careers page",
                                                 issued_by:) do
        run = finder.run(Resolution.targets([ company ]), command: "resolve")
        result = run.results.first
        Ingest.new(run_id: run.id).resolution(result) if result
        [ run, result ]
      end
      unless result
        return Outcome.new(summary: "Stopped before its careers page was found: #{run.stopped || 'no result written'}.",
                           tally: {}, cost_usd: 0.0, run_id: run.id, run_dir: run.dir, stopped: run.stopped || "no result")
      end

      company.reload
      summary =
        case company.resolution_status
        when "resolved"
          "Careers page found: #{company.careers_page_url} (#{company.resolution_method}, #{company.resolution_confidence})."
        when "candidate"
          "A careers page was found, but only at low confidence: #{company.resolution_candidate_url}. " \
            "Confirm it, reject it, or set the right one on the company's page."
        else
          "No careers page found (#{company.resolution_failure || result['reason']}). " \
            "Set it by hand on the company's page if you know it."
        end
      Outcome.new(summary: summary, tally: {}, cost_usd: cost(result), run_id: run.id, run_dir: run.dir, stopped: run.stopped)
    end

    def read_list(company, worker, issued_by: AuditEvent::OPERATOR)
      start = -> { worker.run([ Targets.verify(company) ], command: "verify") }
      record(start, purpose: "check now: #{company.name}", issued_by:) do |result, verdicts|
        found = verdicts.map { |v| v["verdict"] || "inconclusive" }.tally
        read = result["outcome"] == "ok" ? "#{result['listing_count']} roles read#{', the whole list' if result['complete']}" : "Not read (#{result['reason']})"
        roles = found.map { |state, count| "#{count} #{Posting::ANSWER_LABELS.fetch(state, 'no answer').downcase}" }
        [ nil, [ "#{read}.", roles.any? ? "Roles on record: #{roles.join(', ')}." : "No role on record here yet." ].join(" ") ]
      end
    end

    # Starts the run and records its one result through the write path, under the
    # verifier's credential for this run; the block turns it into an answer and a
    # summary. The suggestions are brought up to date after, by the suggester.
    def record(start, purpose:, issued_by: AuditEvent::OPERATOR)
      run, result, tally = Authority.run(Ingest::ACTOR, scopes: CHECKING, purpose: purpose, issued_by:) do
        run = start.call
        result = run.results.first
        [ run, result, (Ingest.new(run_id: run.id).verification(result) if result) ]
      end
      unless result
        return Outcome.new(summary: "Stopped before a result: #{run.stopped || 'no result written'}.", tally: {},
                           cost_usd: 0.0, run_id: run.id, run_dir: run.dir, stopped: run.stopped || "no result")
      end

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
