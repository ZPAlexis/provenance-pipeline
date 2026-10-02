module Verifier
  # The one write path for what the worker reports. Every result is checked
  # against ResultContract first; each is written whole or not at all.
  #
  # Every check becomes a PageCheck, and every LLM call an LlmCall under it:
  # the evidence, kept whatever the outcome. What a result changes on a company
  # or a posting goes through AuditEvent.record_write! as agent:verifier, with
  # the model that served the result's LLM calls as model_version.
  #
  # Verdicts, per Posting's verification contract: a verdict that changes is an
  # audited update; a check that confirms the verdict refreshes last_checked_at
  # and what it observed (counts drift) with no audit event, because the page
  # check is its provenance; an inconclusive check (no verdict) leaves the
  # posting alone, and the page check keeps why. The verifier's verdict replaces
  # an imported one; the imported label stays in the posting's enrichment and
  # history.
  class Ingest
    ACTOR = "agent:verifier".freeze

    class InvalidResult < StandardError; end

    def initialize(run_id:)
      @run_id = run_id
    end

    # Returns the result's outcome. Raises InvalidResult, writing nothing, for
    # a result that breaks the contract or names no known company.
    def resolution(result)
      errors = ResultContract.resolution_errors(result)
      raise InvalidResult, "#{result.try(:[], 'target_id') || '(no target)'}: #{errors.join('; ')}" if errors.any?

      company = Company.find_by(id: result["target_id"]) or
        raise InvalidResult, "#{result['target_id']}: no such company"

      ApplicationRecord.transaction do
        result["checks"].each { |check| record_check(company, check, purpose: "resolution") }
        apply_resolution(company, result) unless result["outcome"] == "error"
      end
      result["outcome"]
    end

    # Returns counts of what happened to the postings: written, unchanged, inconclusive.
    def verification(result)
      errors = ResultContract.verification_errors(result)
      raise InvalidResult, "#{result.try(:[], 'target_id') || '(no target)'}: #{errors.join('; ')}" if errors.any?

      company = Company.find_by(id: result["target_id"]) or
        raise InvalidResult, "#{result['target_id']}: no such company"
      postings = company.postings.where(id: result["verdicts"].pluck("posting_id")).index_by(&:id)
      strays = result["verdicts"].pluck("posting_id") - postings.keys
      raise InvalidResult, "#{result['target_id']}: postings #{strays.join(', ')} are not this company's" if strays.any?

      ApplicationRecord.transaction do
        checks = result["checks"].map { |check| record_check(company, check, purpose: "verification") }
        record_matches(checks.first, result) if checks.any?
        result["verdicts"].each_with_object(Hash.new(0)) do |verdict, tally|
          tally[apply_verdict(postings.fetch(verdict["posting_id"]), verdict, result)] += 1
        end
      end
    end

    private

    # Each posting's outcome, on the check that read the page, and the near-miss call under it.
    def record_matches(page_check, result)
      page_check.update!(matches: result["verdicts"].map do |verdict|
        verdict.slice("posting_id", "verdict", "method", "listing_index", "location_note", "reasoning")
      end)
      record_llm(page_check, result["match_llm"], called_at: page_check.checked_at) if result["match_llm"]
    end

    # Returns :written, :unchanged, or :inconclusive.
    def apply_verdict(posting, verdict, result)
      return :inconclusive if verdict["verdict"].nil?

      checked_at = Time.iso8601(result["checks"].first["checked_at"])
      posting.assign_attributes(
        verification_state: verdict["verdict"],
        roles_listed_count: (result["listing_count"] if result["outcome"] == "ok"),
        work_mode: observed_work_mode(verdict),
        last_checked_at: checked_at
      )
      # Only a verdict that changes is a change worth an audit event. The rest of
      # what a check observed (counts drift from check to check) is refreshed with
      # it, and the page check is the provenance.
      unless posting.verification_state_changed?
        posting.save!
        return :unchanged
      end

      posting.save!
      AuditEvent.record_write!(posting, actor: ACTOR, model_version: model_version(result),
                                        reasoning: verdict_reasoning(verdict, result))
      :written
    end

    # As the matched listing states it; nil when it was not observed (Posting's contract).
    def observed_work_mode(verdict)
      mode = verdict.dig("listing", "work_mode")
      mode unless mode.nil? || mode == "unknown"
    end

    def verdict_reasoning(verdict, result)
      read = if result["outcome"] == "ok"
        "#{result['listing_count']} roles read on #{result['url']}#{', the whole list' if result['complete']}."
      end
      [ verdict["reasoning"], verdict["location_note"], read, "Run #{@run_id}." ].compact_blank.join(" ")
    end

    def record_check(company, check, purpose:)
      page_check = company.page_checks.create!(
        run_id: @run_id,
        purpose: purpose,
        step: check["step"],
        url: check["url"],
        final_url: check["final_url"],
        outcome: check["outcome"],
        reason: check["reason"],
        read_via: check["method"],
        ats_vendor: check.dig("ats", "vendor"),
        ats_board: check.dig("ats", "board"),
        http_status: check["http_status"],
        listing_count: check["listing_count"],
        stated_total: check["stated_total"],
        explicit_no_openings: check["explicit_no_openings"] || false,
        listings_incomplete: check["listings_incomplete"] || false,
        many_employers: check["many_employers"] || false,
        single_job_posting: check["single_job_posting"] || false,
        next_page_url: check["next_page_url"],
        input_truncated: check["input_truncated"] || false,
        listings: check["listings"] || [],
        notes: check["notes"],
        content_hash: check["content_hash"],
        checked_at: check["checked_at"],
        duration_ms: check["duration_ms"]
      )
      record_llm(page_check, check["llm"], called_at: check["checked_at"]) if check["llm"]
      page_check
    end

    def record_llm(page_check, llm, called_at:)
      page_check.llm_calls.create!(
        run_id: @run_id,
        purpose: llm["purpose"],
        model: llm["model"],
        settings: llm["settings"] || {},
        prompt_version: llm["prompt_version"],
        input_tokens: llm["input_tokens"],
        output_tokens: llm["output_tokens"],
        cost_usd: llm["cost_usd"],
        called_at: called_at
      )
    end

    def apply_resolution(company, result)
      url = result["careers_page_url"]
      previous_page = company.careers_page_url

      case result["outcome"]
      when "resolved"
        company.assign_attributes(
          careers_page_url: url,
          ats_type: Resolution.ats_type(company, url, result.dig("ats", "vendor")),
          resolution_status: "resolved", resolution_method: result["method"],
          resolution_confidence: result["confidence"], resolution_candidate_url: nil,
          resolution_failure: nil, resolved_at: Time.current
        )
      when "candidate"
        company.assign_attributes(
          resolution_status: "candidate", resolution_method: result["method"],
          resolution_confidence: result["confidence"], resolution_candidate_url: url, resolution_failure: nil
        )
        # A suggested kind waits for the operator; a kind they set is never overwritten.
        if result["kind_suggestion"] && company.kind.nil?
          company.assign_attributes(kind_suggestion: result["kind_suggestion"], kind_evidence: result["kind_evidence"])
        end
      when "failed"
        company.assign_attributes(
          resolution_status: "failed", resolution_failure: result["failure"],
          resolution_method: nil, resolution_confidence: nil, resolution_candidate_url: nil
        )
      end
      return unless company.changed?

      company.save!
      AuditEvent.record_write!(
        company, actor: ACTOR, model_version: model_version(result),
        reasoning: reasoning(result, previous_page)
      )
    end

    def reasoning(result, previous_page)
      checks = result["checks"]
      text =
        case result["outcome"]
        when "resolved"
          found = Resolution.found_check(result)
          listings = found && found["listing_count"] ? "; #{found['listing_count']} listings read there" : ""
          "Careers page found by #{result['method']} at #{result['confidence']} confidence#{listings}." \
            "#{replacement_note(result, previous_page)}"
        when "candidate"
          "A #{result['confidence']}-confidence careers page, found by #{result['method']}, held for a human to confirm."
        else
          "No careers page found (#{result['failure']}) after #{checks.size} checks."
        end
      [ text, result["evidence"], "Run #{@run_id}." ].compact_blank.join(" ")
    end

    # Why the page on record changed, when it did: it redirected, or it was
    # tried first and did not yield listings.
    def replacement_note(result, previous_page)
      return "" if previous_page.blank? || previous_page == result["careers_page_url"]
      return " The page on record, #{previous_page}, leads here." if result["method"] == "imported"

      " It replaces #{previous_page}, which was not a page listing the company's jobs when checked."
    end

    # The model that served this result's LLM calls, with its request settings.
    def model_version(result)
      llm = (result["checks"].filter_map { |check| check["llm"] } + [ result["match_llm"] ].compact).first or return
      [ llm["model"], (llm["settings"].to_json if llm["settings"].present?) ].compact.join(" ")
    end
  end
end
