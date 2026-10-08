module Verifier
  # Each role's own page at the employer, learned from the listing it matched at
  # its latest verification. Verification writes it as it goes; this fills it in
  # for postings matched before it existed, from the checks already stored, at
  # no cost. Written as the verifier, audited, with the check it came from.
  module JobUrls
    module_function

    # Returns how many postings learned their link.
    def backfill!(postings = Posting.not_dismissed.where(job_url: nil))
      postings.includes(:company).count do |posting|
        found = matched_listing(posting) or next false
        listing, check = found
        posting.update!(job_url: listing["url"])
        AuditEvent.record_write!(
          posting, actor: Ingest::ACTOR,
          reasoning: "Its own page at the employer, learned from the listing it matched " \
                     "(\"#{listing['title']}\") in check #{check.id} of run #{check.run_id}."
        )
        true
      end
    end

    # The listing a posting's latest live match pointed to, with the check that recorded it;
    # nil when there is none, or when it has no link.
    #
    # Only the latest word on the role counts, and only a match on its title: a
    # role a later check found gone, or a near-miss the LLM judged, leaves no
    # link. Matched by link first, a wrong link would keep calling a closed role
    # "still listed" for good (Baker Hughes, 2026-10-07).
    def matched_listing(posting)
      check = posting.company.page_checks.where(purpose: "verification")
                     .where("matches @> ?", [ { posting_id: posting.id } ].to_json)
                     .order(checked_at: :desc).first or return
      match = check.matches.find { |m| m["posting_id"] == posting.id }
      return unless match["verdict"] == "verified_live" && Ingest::LINK_METHODS.include?(match["method"])

      listing = run_listings(check)[match["listing_index"].to_i] if match["listing_index"]
      # The reasoning names the listing it matched: a guard against reading the wrong one.
      return unless listing && listing["url"].present? && match["reasoning"].to_s.include?("\"#{listing['title']}\"")

      [ listing, check ]
    end

    # Every listing a verification read, in the order the worker matched against
    # them (workers/verifier pipeline.read_all). Pages are taken in the order the
    # result listed them, which is the order they were stored.
    def run_listings(check)
      listed(check.company.page_checks.where(run_id: check.run_id, purpose: "verification").order(:created_at, :id))
    end

    # The listings of a list read page by page: the first page whole, then each
    # next page's listings not seen before, up to a page with none.
    def listed(pages)
      first, *rest = pages
      listings = first.listings.dup
      seen = listings.to_set { |listing| listing_key(listing) }
      rest.each do |page|
        fresh = page.listings.reject { |listing| seen.include?(listing_key(listing)) }
        break if fresh.empty?

        listings.concat(fresh)
        seen.merge(fresh.map { |listing| listing_key(listing) })
      end
      listings
    end

    def listing_key(listing)
      listing["url"].presence || [ listing["title"].to_s.strip.downcase, listing["location"].to_s.strip.downcase ]
    end
  end
end
