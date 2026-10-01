module Verifier
  # Which companies resolution works on, and what the worker is told about them.
  module Resolution
    # A posting whose employer is withheld names a placeholder, not a company:
    # there is nothing to resolve, so it is never sent to the worker.
    ANONYMISED = /\A\s*(?:empresa\s+)?confiden(?:cial|tial)(?:\s+(?:company|employer))?\s*\z/i

    module_function

    def anonymised?(company) = company.name.to_s.match?(ANONYMISED)

    # A page already on record is tried first, as the imported step.
    def targets(companies)
      companies.reject { |company| anonymised?(company) }.map do |company|
        { id: company.id, label: company.name, domain: company.domain, name: company.name,
          known_url: company.careers_page_url }
      end
    end

    # Records anonymised companies as resolution failures. Returns how many changed.
    def mark_anonymised!(companies, actor: Ingest::ACTOR)
      companies.select { |company| anonymised?(company) }.count do |company|
        ApplicationRecord.transaction do
          company.update!(resolution_status: "failed", resolution_failure: "anonymised")
          AuditEvent.record_write!(
            company, actor: actor,
            reasoning: "The employer is withheld on its postings (#{company.name.inspect}): there is no company to resolve."
          )
        end
      end
    end

    # The check that read the page a result settled on: by its address, or by its
    # ATS board, since a job's address read through a board is watched as the board.
    def found_check(result)
      url, board = result["careers_page_url"], result["ats"]
      Array(result["checks"]).reverse.find do |check|
        [ check["final_url"], check["url"] ].include?(url) || (board.present? && check["ats"] == board)
      end
    end

    # Hosts that are a known ATS's boards, for a page a human sets: the worker
    # names the vendor for pages it reads, but a page set by hand has no check yet.
    VENDOR_HOSTS = {
      "greenhouse" => /(?:\A|\.)greenhouse\.io\z/,
      "lever" => /(?:\A|\.)lever\.co\z/,
      "ashby" => /(?:\A|\.)ashbyhq\.com\z/,
      "workday" => /\.myworkdayjobs\.com\z/,
      "workable" => /(?:\A|\.)workable\.com\z/
    }.freeze

    def vendor_for(url)
      host = URI.parse(url.to_s).host.to_s.downcase
      VENDOR_HOSTS.find { |_vendor, pattern| host.match?(pattern) }&.first
    rescue URI::InvalidURIError
      nil
    end

    # A known ATS by name; otherwise the company's own site, or another host.
    def ats_type(company, url, vendor)
      return vendor if vendor.present?

      host = URI.parse(url).host.to_s.downcase
      site = company.domain.to_s.downcase.delete_prefix("www.")
      site.present? && (host == site || host.end_with?(".#{site}")) ? "own_site" : "other"
    rescue URI::InvalidURIError
      "other"
    end
  end
end
