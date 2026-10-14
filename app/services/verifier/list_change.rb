module Verifier
  # Whether a company's list of roles changed a lot between two whole reads of
  # the same page (1.4): at least half the earlier list gone, or half the later
  # list new, and at least 5 roles either way. Only whole reads are compared (the
  # worker's own answer, stored from 1.4 on): a role missing from part of a list
  # has not gone. A list that changes this much is often a different page now (a
  # redirect, a redesign, a parent company's list), and every verdict there
  # rests on it. Shared by the review queue and what changed.
  module ListChange
    AT_LEAST = 5
    SHARE = 0.5

    Change = Data.define(:company, :before, :after, :gone, :added, :before_size, :after_size) do
      def a_lot? = gone + added >= AT_LEAST && (gone >= SHARE * before_size || added >= SHARE * after_size)

      def url = after.url

      def summary
        "#{gone} of #{before_size} roles gone and #{added} of #{after_size} new between whole reads of " \
          "#{url} on #{before.checked_at.to_date} and #{after.checked_at.to_date}"
      end
    end

    module_function

    # Each verification run's first check that read the company's list whole,
    # oldest first, since its careers page was last settled (a page set or found
    # anew starts the comparison over).
    def whole_reads(company)
      reads = company.page_checks.where(purpose: "verification", step: nil, complete: true)
      reads = reads.where(checked_at: company.resolved_at..) if company.resolved_at
      reads.order(:checked_at, :created_at)
    end

    # Every change a lot between consecutive whole reads of one page (its address,
    # or the ATS board read), oldest first.
    def changes(company)
      whole_reads(company).to_a.group_by { |read| source(read) }.values.flat_map do |reads|
        reads.each_cons(2).map { |before, after| compare(before, after) }.select(&:a_lot?)
      end.sort_by { |change| change.after.checked_at }
    end

    def latest(company) = changes(company).last

    # Every change a lot whose later read was made at or after `from`, across companies.
    def since(from)
      ids = PageCheck.where(purpose: "verification", step: nil, complete: true, checked_at: from..).distinct.pluck(:company_id)
      Company.where(id: ids).flat_map { |company| changes(company).select { |change| change.after.checked_at >= from } }
             .sort_by { |change| change.after.checked_at }.reverse
    end

    def compare(before, after)
      was = keys(before)
      now = keys(after)
      Change.new(company: after.company, before: before, after: after, gone: (was - now).size, added: (now - was).size,
                 before_size: was.size, after_size: now.size)
    end

    # A run's listings as roles: by their own link (tracking parameters aside, and case: a board's
    # slug is read as /Rogo/ one day and /rogo/ the next), else by title and place.
    def keys(read)
      JobUrls.run_listings(read).to_set do |listing|
        url = listing["url"].presence
        url ? Capture.link_key(url).downcase : [ listing["title"].to_s.squish.downcase, listing["location"].to_s.squish.downcase ]
      end
    end

    def source(read) = read.ats_vendor ? "#{read.ats_vendor}/#{read.ats_board}" : read.url
  end
end
