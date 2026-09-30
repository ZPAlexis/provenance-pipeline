module Verifier
  # Low-confidence finds wait here for a human. Confirming one makes it the
  # watched careers page; rejecting one records the refusal. Either way the
  # write is audited under the human's own actor identity.
  module Candidates
    ACTOR = AuditEvent::OPERATOR

    class NotACandidate < StandardError; end

    module_function

    def pending = Company.resolution_candidates.order(:name)

    def confirm!(company, actor: ACTOR)
      require_candidate!(company)
      url = company.resolution_candidate_url
      method = company.resolution_method
      check = company.page_checks.where(final_url: url).or(company.page_checks.where(url: url)).order(:checked_at).last

      company.update!(
        careers_page_url: url, ats_type: Resolution.ats_type(company, url, check&.ats_vendor),
        resolution_status: "resolved", resolution_confidence: "confirmed",
        resolution_candidate_url: nil, resolved_at: Time.current
      )
      AuditEvent.record_write!(company, actor: actor, reasoning: "Confirmed by hand: the candidate careers page found by #{method}.")
    end

    def reject!(company, actor: ACTOR)
      require_candidate!(company)
      url = company.resolution_candidate_url

      company.update!(
        resolution_status: "failed", resolution_failure: "rejected",
        resolution_method: nil, resolution_confidence: nil, resolution_candidate_url: nil
      )
      AuditEvent.record_write!(company, actor: actor, reasoning: "Rejected by hand: #{url} is not this company's careers page.")
    end

    def require_candidate!(company)
      return if company.resolution_status == "candidate"

      raise NotACandidate, "#{company.name} has no candidate careers page (status: #{company.resolution_status.inspect})"
    end
  end
end
