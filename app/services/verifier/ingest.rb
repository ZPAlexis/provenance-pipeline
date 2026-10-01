module Verifier
  # The one write path for what the worker reports. Every result is checked
  # against ResultContract first; each is written whole or not at all.
  #
  # Every check becomes a PageCheck, and every LLM call an LlmCall under it:
  # the evidence, kept whatever the outcome. What a result changes on the
  # company goes through AuditEvent.record_write! as agent:verifier, with the
  # model that served the result's LLM calls as model_version.
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

    private

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
      return unless (llm = check["llm"])

      page_check.llm_calls.create!(
        run_id: @run_id,
        purpose: llm["purpose"],
        model: llm["model"],
        settings: llm["settings"] || {},
        prompt_version: llm["prompt_version"],
        input_tokens: llm["input_tokens"],
        output_tokens: llm["output_tokens"],
        cost_usd: llm["cost_usd"],
        called_at: check["checked_at"]
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
      llm = result["checks"].filter_map { |check| check["llm"] }.first or return
      [ llm["model"], (llm["settings"].to_json if llm["settings"].present?) ].compact.join(" ")
    end
  end
end
