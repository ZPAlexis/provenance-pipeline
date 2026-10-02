module Verifier
  # Low-confidence finds wait here for a human. Confirming one makes it the
  # watched careers page; rejecting one records the refusal; and when the human
  # knows the right page, they set it. Every write is audited under the human's
  # own actor identity.
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
        careers_page_url: url, ats_type: Resolution.ats_type(company, url, check&.ats_vendor || Resolution.vendor_for(url)),
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

    # The page a human found: for a candidate that was wrong, a company
    # resolution could not resolve, or a watched page that turned out wrong.
    # Whatever the company's state, it becomes resolved by hand, and the human's
    # reason goes on the record.
    def set_page!(company, url, reasoning:, actor: ACTOR)
      raise ArgumentError, "#{url.inspect} is not an http(s) address" unless ResultContract.web_url?(url)
      raise ArgumentError, "say how you know it is the page: it becomes the audit reasoning" if reasoning.blank?

      ApplicationRecord.transaction do
        company.update!(
          careers_page_url: url, ats_type: Resolution.ats_type(company, url, Resolution.vendor_for(url)),
          resolution_status: "resolved", resolution_method: "manual", resolution_confidence: "confirmed",
          resolution_candidate_url: nil, resolution_failure: nil, resolved_at: Time.current
        )
        AuditEvent.record_write!(company, actor: actor, reasoning: "Set by hand. #{reasoning}")
      end
    end

    # What kind of company it is, as the operator judges it: a recruiter's own
    # board of client roles then counts as its careers page, and an aggregator's
    # postings are known to belong to other employers.
    def set_kind!(company, kind, reasoning: nil, actor: ACTOR)
      raise ArgumentError, "kind is one of #{Company::KINDS.join(', ')}" unless Company::KINDS.include?(kind)

      ApplicationRecord.transaction do
        company.update!(kind: kind, kind_suggestion: nil)
        AuditEvent.record_write!(company, actor: actor,
                                          reasoning: [ "Kind set by hand: #{kind}.", reasoning.presence ].compact.join(" "))
      end
    end

    def require_candidate!(company)
      return if company.resolution_status == "candidate"

      raise NotACandidate, "#{company.name} has no candidate careers page (status: #{company.resolution_status.inspect})"
    end
  end
end
