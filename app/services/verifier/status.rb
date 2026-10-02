module Verifier
  # One company at a glance, for the operator: how its careers page was
  # resolved, the last checks of its pages, its postings and their verdicts,
  # and the latest writes to it. Read-only.
  module Status
    CHECKS = 5
    EVENTS = 5

    module_function

    # By id, by exact name (any case), or by a fragment of the name when only one company has it.
    def find(query)
      query = query.to_s.strip
      return if query.empty?
      return Company.find_by(id: query) if query.match?(/\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/)

      exact = Company.find_by("lower(name) = ?", query.downcase)
      return exact if exact

      matches = Company.where("name ILIKE ?", "%#{Company.sanitize_sql_like(query)}%").limit(2).to_a
      matches.first if matches.one?
    end

    def lines(company)
      [ *company_lines(company), "", *check_lines(company), "", *posting_lines(company), "", *event_lines(company),
        "", *next_steps(company) ]
    end

    def company_lines(company)
      [
        "#{company.name} (#{company.domain || 'no domain'})  id #{company.id}",
        "  resolution: #{company.resolution_status || 'not attempted'}" +
          [ company.resolution_method, company.resolution_confidence ].compact.map { |v| ", #{v}" }.join +
          (company.resolution_failure ? ", failure #{company.resolution_failure}" : ""),
        "  watched page: #{company.careers_page_url || '-'}#{" (#{company.ats_type})" if company.ats_type}",
        *("  candidate: #{company.resolution_candidate_url}" if company.resolution_candidate_url)
      ]
    end

    def check_lines(company)
      checks = company.page_checks.order(checked_at: :desc).limit(CHECKS).to_a
      return [ "Page checks: none" ] if checks.empty?

      [ "Last #{checks.size} page checks (newest first):" ] + checks.map do |check|
        flags = { "partial" => check.listings_incomplete, "one job" => check.single_job_posting,
                  "many employers" => check.many_employers }.select { |_, on| on }.keys
        listed = check.listing_count.nil? ? "" : ", #{check.listing_count} listed"
        listed += " of #{check.stated_total}" if check.stated_total
        "  #{check.checked_at.utc.strftime('%Y-%m-%d %H:%M')}  #{check.purpose}/#{check.step || '-'}  " \
          "#{check.outcome}#{listed}#{" [#{flags.join(', ')}]" if flags.any?}#{" (#{check.reason})" if check.reason}\n" \
          "      #{check.url}"
      end
    end

    def posting_lines(company)
      postings = company.postings.order(:role_title).to_a
      return [ "Postings: none" ] if postings.empty?

      [ "Postings (#{postings.size}):" ] + postings.map do |posting|
        checked = posting.last_checked_at ? " on #{posting.last_checked_at.utc.to_date}" : ""
        label = TestB.label_for(posting)
        "  #{posting.role_title}: #{posting.verification_state}#{checked}" \
          "#{" (Clay said #{label})" if label && label != posting.verification_state}\n" \
          "      #{posting.posting_url}  (posting #{posting.id})"
      end
    end

    def event_lines(company)
      events = company.audit_events.order(occurred_at: :desc).limit(EVENTS).to_a
      [ "Last #{events.size} writes to the company (newest first):" ] + events.map do |event|
        "  #{event.occurred_at.utc.strftime('%Y-%m-%d %H:%M')}  #{event.actor} #{event.action} " \
          "#{event.changes_made.keys.join(', ')}\n      #{event.reasoning.to_s.squish.truncate(160)}"
      end
    end

    def next_steps(company)
      set = "URL=\"https://...\" REASON=\"...\" bin/rails \"verifier:set_page[#{company.id}]\""
      case company.resolution_status
      when "candidate"
        [ "Next: bin/rails \"verifier:confirm[#{company.id}]\" or \"verifier:reject[#{company.id}]\", or #{set}" ]
      else
        [ "To change its watched page: #{set}" ]
      end
    end
  end
end
