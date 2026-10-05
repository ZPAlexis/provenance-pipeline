module Verifier
  # What the worker is sent about a company, built from the record.
  module Targets
    JOB_URLS = 1 # role links sent for a board search: one job page is enough to show a board behind the site

    module_function

    # A company's watched page and postings, with the two ways a run pays less:
    # the board confirmed to list the same roles, read in place of the page; and
    # what each page of its list showed when last read, reused while the page's
    # role links are unchanged. The worker decides on reuse, and reads in full
    # at least every 14 days.
    def verify(company)
      {
        id: company.id, url: company.careers_page_url, label: company.name, domain: company.domain, name: company.name,
        postings: company.postings.map { |p| { id: p.id, title: p.role_title, location: p.location } },
        board: company.board_in_use, previous: previous_reads(company)
      }
    end

    # The latest read of each address whose listings the LLM read (or carried over from such a read).
    def previous_reads(company)
      company.page_checks.where(outcome: "ok", read_via: PageCheck::PAGE_READS)
             .select("DISTINCT ON (page_checks.url) page_checks.*").order(:url, checked_at: :desc)
             .map do |check|
        {
          page_check_id: check.id, url: check.url, final_url: check.final_url, listings: check.listings,
          listing_count: check.listing_count, stated_total: check.stated_total,
          explicit_no_openings: check.explicit_no_openings, listings_incomplete: check.listings_incomplete,
          many_employers: check.many_employers, single_job_posting: check.single_job_posting,
          next_page_url: check.next_page_url, content_hash: check.content_hash,
          # Before reuse existed, every read was a full one: its check time is when the listings were read.
          listings_read_at: (check.listings_read_at || check.checked_at).utc.iso8601
        }
      end
    end

    # A company whose watched page the LLM had to read at its latest check, with
    # the distinct roles every page of that read showed, and a few of their links
    # (a board behind the company's own site shows only on its job pages): is
    # there a free board listing the same? Nil when its page is read for free
    # already, or when its board was confirmed after that read.
    def board(company)
      latest = company.page_checks.where(purpose: "verification").order(checked_at: :desc).first
      return unless latest && PageCheck::PAGE_READS.include?(latest.read_via)
      return if company.board_confirmed_at && company.board_confirmed_at > latest.checked_at

      reads = company.page_checks.where(run_id: latest.run_id, purpose: "verification", read_via: PageCheck::PAGE_READS)
      listings = reads.flat_map(&:listings)
      { id: company.id, name: company.name, domain: company.domain, titles: listings.pluck("title").uniq,
        job_urls: listings.pluck("url").compact.uniq.first(JOB_URLS) }
    end

    # What reading a company's watched page in full cost the last time: the LLM
    # calls behind every page of its latest verification, counting a reused page
    # at what the read it reused cost. Nil when it has never been verified.
    def full_read_cost(company)
      latest = company.page_checks.where(purpose: "verification").order(checked_at: :desc).first or return
      checks = company.page_checks.where(run_id: latest.run_id, purpose: "verification")
      reads = checks.map { |check| check.read_via == "reused" ? check.reused_from_id : check.id }.compact
      LlmCall.where(page_check_id: reads, purpose: "extract").sum(:cost_usd).to_f
    end
  end
end
