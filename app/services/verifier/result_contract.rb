module Verifier
  # The fixed format every worker result is checked against before anything is
  # written. The worker is a separate process on the far side of a file; its
  # output is data to validate, never trusted as-is. Mirrors
  # workers/verifier/src/verifier/contract.py.
  module ResultContract
    RESOLUTION_OUTCOMES = %w[resolved candidate failed error].freeze
    # What the worker can report. "anonymised" and "rejected" are decided in Rails.
    WORKER_FAILURES = %w[no_domain not_found blocked inaccessible].freeze
    WORKER_CONFIDENCES = %w[high medium low].freeze

    module_function

    # Returns a list of problems; empty when the result may be ingested.
    def resolution_errors(result)
      return [ "not an object" ] unless result.is_a?(Hash)

      errors = []
      errors << "kind must be resolution" unless result["kind"] == "resolution"
      errors << "target_id is missing" if result["target_id"].blank?
      outcome = result["outcome"]
      errors << "unknown outcome #{outcome.inspect}" unless RESOLUTION_OUTCOMES.include?(outcome)

      if %w[resolved candidate].include?(outcome)
        errors << "careers_page_url must be an http(s) URL" unless web_url?(result["careers_page_url"])
        errors << "unknown method #{result['method'].inspect}" unless (Company::RESOLUTION_METHODS - %w[manual]).include?(result["method"])
        errors << "unknown confidence #{result['confidence'].inspect}" unless WORKER_CONFIDENCES.include?(result["confidence"])
        # Low confidence is exactly what a human confirms; it is never resolved automatically.
        errors << "a #{outcome} result cannot be #{result['confidence']} confidence" if (outcome == "resolved") == (result["confidence"] == "low")
      end
      errors << "unknown failure #{result['failure'].inspect}" if outcome == "failed" && !WORKER_FAILURES.include?(result["failure"])

      checks = result["checks"]
      return errors << "checks must be a list" unless checks.is_a?(Array)

      checks.each_with_index { |check, index| errors.concat(page_errors(check).map { |error| "check #{index + 1}: #{error}" }) }
      errors
    end

    VERIFICATION_OUTCOMES = %w[ok inaccessible error].freeze
    MATCH_METHODS = %w[exact variant llm none].freeze

    def verification_errors(result)
      return [ "not an object" ] unless result.is_a?(Hash)

      errors = []
      errors << "kind must be verification" unless result["kind"] == "verification"
      errors << "target_id is missing" if result["target_id"].blank?
      errors << "url must be an http(s) URL" unless web_url?(result["url"])
      errors << "unknown outcome #{result['outcome'].inspect}" unless VERIFICATION_OUTCOMES.include?(result["outcome"])
      errors << "complete must be true or false" unless [ true, false ].include?(result["complete"])
      errors.concat(llm_errors(result["match_llm"]).map { |error| "match_llm #{error}" }) if result["match_llm"]

      checks, verdicts = result["checks"], result["verdicts"]
      return errors << "checks and verdicts must be lists" unless checks.is_a?(Array) && verdicts.is_a?(Array)

      checks.each_with_index { |check, index| errors.concat(page_errors(check).map { |error| "check #{index + 1}: #{error}" }) }
      verdicts.each_with_index do |verdict, index|
        errors.concat(verdict_errors(verdict, complete: result["complete"]).map { |error| "verdict #{index + 1}: #{error}" })
      end
      errors
    end

    # A negative is written only from the whole list: checked here too, not left to the worker alone.
    def verdict_errors(verdict, complete:)
      return [ "not an object" ] unless verdict.is_a?(Hash)

      errors = []
      errors << "posting_id is missing" if verdict["posting_id"].blank?
      errors << "unknown verdict #{verdict['verdict'].inspect}" unless verdict["verdict"].nil? || Posting::VERDICTS.include?(verdict["verdict"])
      errors << "unknown method #{verdict['method'].inspect}" unless MATCH_METHODS.include?(verdict["method"])
      errors << "reasoning is missing" if verdict["reasoning"].blank?
      errors << "not_found from part of a list" if verdict["verdict"] == "not_found" && !complete
      errors
    end

    def page_errors(check)
      return [ "not an object" ] unless check.is_a?(Hash)

      errors = []
      errors << "url must be an http(s) URL" unless web_url?(check["url"])
      errors << "unknown outcome #{check['outcome'].inspect}" unless PageCheck::OUTCOMES.include?(check["outcome"])
      errors << "unknown step #{check['step'].inspect}" unless check["step"].nil? || PageCheck::STEPS.include?(check["step"])
      errors << "checked_at must be an ISO 8601 time" unless iso8601?(check["checked_at"])
      errors << "listing_count must be a count" unless check["listing_count"].nil? || count?(check["listing_count"])
      listings = check["listings"]
      unless listings.nil? || (listings.is_a?(Array) && listings.all? { |listing| listing.is_a?(Hash) && listing["title"].is_a?(String) })
        errors << "listings must each have a title"
      end
      errors.concat(llm_errors(check["llm"]).map { |error| "llm #{error}" }) if check["llm"]
      errors
    end

    def llm_errors(llm)
      return [ "is not an object" ] unless llm.is_a?(Hash)

      errors = []
      errors << "model is missing" if llm["model"].blank?
      errors << "prompt_version is missing" if llm["prompt_version"].blank?
      errors << "unknown purpose #{llm['purpose'].inspect}" unless LlmCall::PURPOSES.include?(llm["purpose"])
      errors << "tokens must be counts" unless count?(llm["input_tokens"]) && count?(llm["output_tokens"])
      errors << "cost_usd must be a non-negative number" unless llm["cost_usd"].is_a?(Numeric) && llm["cost_usd"] >= 0
      errors
    end

    def web_url?(value)
      value.is_a?(String) && URI.parse(value).then { |uri| uri.is_a?(URI::HTTP) && uri.host.present? }
    rescue URI::InvalidURIError
      false
    end

    def iso8601?(value)
      value.is_a?(String) && Time.iso8601(value).present?
    rescue ArgumentError
      false
    end

    def count?(value) = value.is_a?(Integer) && value >= 0
  end
end
