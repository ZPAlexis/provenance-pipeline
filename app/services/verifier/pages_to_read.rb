module Verifier
  # The careers pages a free check left unread (4f): those a tracked company's latest read of its list could not list
  # without the AI (`needs_reading`), oldest first, for the operator's own AI assistant to read, or a check that pays.
  # Worked out from the record: the latest check of each company's careers page, and the pages after it in that run
  # (a list's next pages). A company read through a free board is never on it: its list needs no reader.
  module PagesToRead
    NEEDS_READING = "needs_reading".freeze

    Page = Data.define(:company, :url, :since, :page_check_id)

    module_function

    def list(companies = CheckAll.companies.to_a)
      companies = companies.reject { |company| Targets.free_read?(company) }.index_by(&:id)
      return [] if companies.empty?

      latest = PageCheck.where(purpose: "verification", company_id: companies.keys)
                        .joins(:company).where("page_checks.url = companies.careers_page_url")
                        .select("DISTINCT ON (page_checks.company_id) page_checks.company_id, page_checks.run_id")
                        .order("page_checks.company_id", "page_checks.checked_at DESC")
                        .map { |check| [ check.company_id, check.run_id ] }.to_h
      PageCheck.where(purpose: "verification", reason: NEEDS_READING, company_id: latest.keys, run_id: latest.values.uniq)
               .order(:checked_at, :created_at)
               .select { |check| latest[check.company_id] == check.run_id }
               .map { |check| Page.new(company: companies.fetch(check.company_id), url: check.url, since: check.checked_at, page_check_id: check.id) }
    end

    # How many pages a check's results left unread, from its results as the worker wrote them.
    def left_by(results) = Array(results).sum { |result| Array(result["checks"]).count { |check| check["reason"] == NEEDS_READING } }
  end
end
