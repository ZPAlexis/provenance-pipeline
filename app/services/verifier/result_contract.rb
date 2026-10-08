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
      unless result["kind_suggestion"].nil? || Company::KIND_SUGGESTIONS.include?(result["kind_suggestion"])
        errors << "unknown kind suggestion #{result['kind_suggestion'].inspect}"
      end

      checks = result["checks"]
      return errors << "checks must be a list" unless checks.is_a?(Array)

      checks.each_with_index { |check, index| errors.concat(page_errors(check).map { |error| "check #{index + 1}: #{error}" }) }
      errors
    end

    VERIFICATION_OUTCOMES = %w[ok inaccessible error].freeze
    # link: the listing at the posting's own address; posting_page: the role's own page showed it.
    MATCH_METHODS = %w[link exact variant llm posting_page none].freeze

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
      if verdicts.any? { |verdict| verdict.is_a?(Hash) && verdict["verdict"] == "not_found" } && read_nothing?(result, checks)
        errors << "not_found from a page that listed no roles and did not say it has none"
      end
      errors
    end

    # A rendered read that found no roles, where no page said it has none: a
    # maintenance screen or an app that never loaded is not a list of zero.
    def read_nothing?(result, checks)
      result["listing_count"].to_i.zero? &&
        checks.none? { |check| check.is_a?(Hash) && check["explicit_no_openings"] } &&
        !checks.first.to_h["method"].to_s.start_with?("ats_api")
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

    BOARD_OUTCOMES = %w[adopted rejected none error].freeze
    # Mirrors workers/verifier/src/verifier/boards.py: a board is adopted only when
    # it lists at least this share of the page's distinct roles.
    ADOPT_OVERLAP = 0.9

    def board_errors(result)
      return [ "not an object" ] unless result.is_a?(Hash)

      errors = []
      errors << "kind must be board" unless result["kind"] == "board"
      errors << "target_id is missing" if result["target_id"].blank?
      outcome = result["outcome"]
      errors << "unknown outcome #{outcome.inspect}" unless BOARD_OUTCOMES.include?(outcome)
      return errors unless %w[adopted rejected].include?(outcome)

      board, overlap = result["board"], result["overlap"]
      unless board.is_a?(Hash) && Company::BOARD_VENDORS.include?(board["vendor"]) && board["board"].is_a?(String) && board["board"].present?
        errors << "board must name a known vendor and its board"
      end
      return errors << "overlap must be a share from 0 to 1" unless overlap.is_a?(Numeric) && overlap.between?(0, 1)

      # Adopted on the roles alone: checked here too, not left to the worker.
      if outcome == "adopted"
        errors << "adopted with only #{(overlap * 100).round}% of the page's roles on the board" if overlap < ADOPT_OVERLAP
        errors << "evidence is missing" if result["evidence"].blank?
      end
      errors
    end

    RULED_OUT = %w[excluded level place work_mode].freeze
    FIT_NOTES = %w[work_mode_not_stated place_not_stated level_not_stated].freeze
    WORK_MODES = [ *SearchProfile::WORK_MODES, "unknown" ].freeze

    # The roles holding a profile title, each suggested or ruled out by one rule, with why.
    def suggestion_errors(result)
      return [ "not an object" ] unless result.is_a?(Hash)

      errors = []
      errors << "kind must be suggestion" unless result["kind"] == "suggestion"
      errors << "target_id is missing" if result["target_id"].blank?
      errors << "unknown outcome #{result['outcome'].inspect}" unless %w[ok error].include?(result["outcome"])
      errors << "weighed must be a count" unless count?(result["weighed"])
      roles = result["roles"]
      return errors << "roles must be a list" unless roles.is_a?(Array)

      roles.each_with_index { |role, index| errors.concat(fit_errors(role).map { |error| "role #{index + 1}: #{error}" }) }
      errors
    end

    def fit_errors(role)
      return [ "not an object" ] unless role.is_a?(Hash)

      errors = []
      errors << "listing_index must be a count" unless count?(role["listing_index"])
      errors << "listing must have a title" unless role["listing"].is_a?(Hash) && role.dig("listing", "title").is_a?(String)
      errors << "title is missing" if role["title"].blank?
      errors << "reasoning is missing" if role["reasoning"].blank?
      errors << "unknown level #{role['level'].inspect}" unless role["level"].nil? || SearchProfile::LEVELS.include?(role["level"])
      errors << "unknown work mode #{role['work_mode'].inspect}" unless WORK_MODES.include?(role["work_mode"])
      errors << "unknown notes #{role['notes'].inspect}" unless role["notes"].is_a?(Array) && (role["notes"] - FIT_NOTES).empty?
      # Suggested, or ruled out by exactly one rule: never both, never neither.
      if role["suggested"] == true
        errors << "a suggested role cannot be ruled out" unless role["ruled_out"].nil?
      elsif role["suggested"] == false
        errors << "unknown rule #{role['ruled_out'].inspect}" unless RULED_OUT.include?(role["ruled_out"])
      else
        errors << "suggested must be true or false"
      end
      errors
    end

    def page_errors(check)
      return [ "not an object" ] unless check.is_a?(Hash)

      errors = []
      errors << "url must be an http(s) URL" unless web_url?(check["url"])
      errors << "unknown outcome #{check['outcome'].inspect}" unless PageCheck::OUTCOMES.include?(check["outcome"])
      errors << "unknown step #{check['step'].inspect}" unless check["step"].nil? || PageCheck::STEPS.include?(check["step"])
      errors << "checked_at must be an ISO 8601 time" unless iso8601?(check["checked_at"])
      unless check["listings_read_at"].nil? || iso8601?(check["listings_read_at"])
        errors << "listings_read_at must be an ISO 8601 time"
      end
      errors << "a reused read must name the read it reused" if check["method"] == "reused" && check["reused_from"].blank?
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
