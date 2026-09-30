module Verifier
  # The resolution test: can resolution find careers pages already on record?
  #
  # Each company's known page is hidden, and the company is resolved from its
  # domain and name alone. An answer is correct when it is the same page, the
  # same ATS board, or shares at least 70% of the known page's distinct titles.
  # Where the answer is a different URL, the known page is checked too, so the
  # two can be compared.
  #
  # Two label shapes need their own comparison (adopted after the 71-company
  # run, 2026-09-30). A label that points at one job, not a careers page, is
  # matched when the answer is on the same careers site. An answer that shows
  # only part of its list is compared the other way round: the share of its own
  # titles on the known page, since page 1 of a list is a subset of it. Titles
  # match when worded differently but one contains the other ("Founding
  # Creative" / "Founding Creative Director").
  #
  # Passes when at least 80% of measured companies are answered correctly AND
  # no automatic answer (high or medium confidence) is wrong: a wrong watched
  # page is the failure that costs most, because nobody looks at it again. A
  # company without a domain, or one robots.txt keeps us off, is reported but not
  # measured, since neither says anything about the resolver. A different page
  # is measured only against a known page that could be read. Read-only: the
  # test writes nothing.
  class ResolutionTest
    REQUIRED_CORRECT = 0.8
    TITLE_OVERLAP = 0.7
    UNMEASURED_FAILURES = %w[no_domain blocked].freeze

    Case = Struct.new(:id, :company, :domain, :known_url, :result, :known_check, keyword_init: true) do
      def outcome = result&.dig("outcome")

      def found_url = result&.dig("careers_page_url")

      def automatic? = outcome == "resolved"

      # The known page, or where it redirects.
      def same_page?
        found_url.present? && [ known_url, known_check&.dig("final_url") ].compact.any? do |url|
          ResolutionTest.page_key(url) == ResolutionTest.page_key(found_url)
        end
      end

      def same_board?
        found, known = result&.dig("ats"), known_check&.dig("ats")
        found.present? && known.present? && ResolutionTest.board_key(found) == ResolutionTest.board_key(known)
      end

      # A label that is one job: the answer is on the same careers site.
      def same_site?
        found_url.present? && single_job_label? &&
          [ known_url, known_check&.dig("final_url") ].compact.any? { |url| ResolutionTest.same_site?(url, found_url, domain) }
      end

      def single_job_label? = ResolutionTest.single_job_url?(known_url)

      # The answer's page shows only part of its list, by the resolver's own rule:
      # a total the page states settles it, otherwise the extractor's flag.
      def partial_answer?
        check = found_check or return false
        return check["listing_count"].to_i < check["stated_total"] if check["stated_total"]

        check["listings_incomplete"] == true
      end

      # The share of the known page's titles on the answer's page. A partial
      # answer may instead show its own titles are on the known page.
      def title_overlap
        known, found = ResolutionTest.titles(known_check), ResolutionTest.titles(found_check)
        return if known.empty? || found.empty?

        share = ->(base, other) { base.count { |title| other.any? { |t| ResolutionTest.titles_match?(title, t) } }.fdiv(base.size) }
        partial_answer? ? [ share.call(known, found), share.call(found, known) ].max : share.call(known, found)
      end

      def found_check
        Array(result&.dig("checks")).reverse.find { |check| [ check["final_url"], check["url"] ].include?(found_url) }
      end

      def correct? = same_page? || same_board? || same_site? || title_overlap.to_f >= TITLE_OVERLAP

      # How it was judged correct, for the report.
      def correct_because
        return "same page" if same_page?
        return "same board" if same_board?
        return "same careers site as the one-job label" if same_site?

        "#{(title_overlap * 100).round}% titles#{' (a partial list)' if partial_answer?}"
      end

      def needs_known_check? = found_url.present? && !same_page?

      def known_readable? = known_check&.dig("outcome") == "ok" && known_check["listing_count"].to_i.positive?

      def measured?
        return false if result.nil?
        return false if outcome == "failed" && UNMEASURED_FAILURES.include?(result["failure"])
        return true unless needs_known_check?

        correct? || known_readable?
      end

      def wrong? = automatic? && measured? && !correct?
    end

    Report = Struct.new(:cases, keyword_init: true) do
      def measured = cases.select(&:measured?)

      def unmeasured = cases.reject(&:measured?)

      def correct = measured.count(&:correct?)

      def share = measured.empty? ? 0.0 : correct.fdiv(measured.size)

      def wrong = measured.select(&:wrong?)

      def passed? = measured.any? && share >= REQUIRED_CORRECT && wrong.empty?

      # [outcome, method, confidence] => companies
      def by_method = cases.filter_map(&:result).map { |r| [ r["outcome"], r["method"], r["confidence"] ] }.tally

      def llm_usages
        cases.flat_map { |c| Array(c.result&.dig("checks")) + [ c.known_check ] }.compact.filter_map { |check| check["llm"] }
      end

      def cost_usd = llm_usages.sum { |llm| llm["cost_usd"].to_f }.round(4)

      def tokens = llm_usages.sum { |llm| llm["input_tokens"].to_i + llm["output_tokens"].to_i }
    end

    # Scheme, "www.", a trailing slash, the query, and the fragment do not make a different page.
    def self.page_key(url)
      uri = URI.parse(url.to_s.strip)
      "#{uri.host.to_s.downcase.delete_prefix('www.')}#{uri.path.to_s.chomp('/')}"
    rescue URI::InvalidURIError
      url.to_s
    end

    def self.board_key(ats) = [ ats["vendor"], ats["board"].to_s.downcase ]

    # A job's own address: a path segment carrying a long id, as most ATSs use.
    def self.single_job_url?(url)
      URI.parse(url.to_s).path.to_s.split("/").any? { |segment| segment.count("0-9") >= 6 }
    rescue URI::InvalidURIError
      false
    end

    # Both on the company's own domain, or on one shared host under the same
    # company path (jobs.smartrecruiters.com/Acme and careers.smartrecruiters.com/Acme).
    def self.same_site?(a, b, domain)
      ua, ub = URI.parse(a), URI.parse(b)
      ha, hb = [ ua, ub ].map { |uri| uri.host.to_s.downcase.delete_prefix("www.") }
      site = domain.to_s.downcase.delete_prefix("www.")
      own = ->(host) { site.present? && (host == site || host.end_with?(".#{site}")) }
      return true if own.call(ha) && own.call(hb)

      segment = ->(uri) { uri.path.to_s.split("/").reject(&:blank?).first.to_s.downcase }
      ha.split(".").last(2) == hb.split(".").last(2) && segment.call(ua).present? && segment.call(ua) == segment.call(ub)
    rescue URI::InvalidURIError
      false
    end

    # Equal, or one title's words all within the other's, when the shorter has at least two.
    def self.titles_match?(a, b)
      return true if a == b

      shorter, longer = [ a, b ].map { |title| title.scan(/[[:alnum:]]+/) }.sort_by(&:size)
      shorter.size >= 2 && (shorter - longer).empty?
    end

    def self.titles(check)
      Array(check&.dig("listings")).map { |listing| listing["title"].to_s.squish.downcase }.uniq
    end

    def initialize(companies)
      @cases = companies.map do |company|
        Case.new(id: company.id, company: company.name, domain: company.domain, known_url: company.careers_page_url)
      end
    end

    # The known page is hidden: resolution starts from the domain and name.
    def targets
      @cases.map { |c| { id: c.id, label: c.company, domain: c.domain, name: c.company, known_url: nil } }
    end

    # The known pages to check: only where resolution answered with a different URL.
    def known_page_targets(resolutions)
      with(resolutions).select(&:needs_known_check?).map do |c|
        { id: c.id, url: c.known_url, label: c.company, domain: c.domain, name: c.company }
      end
    end

    def evaluate(resolutions, known_checks = [])
      checks = known_checks.index_by { |check| check["target_id"] }
      Report.new(cases: with(resolutions).each { |c| c.known_check = checks[c.id] })
    end

    private

    def with(resolutions)
      by_id = resolutions.index_by { |result| result["target_id"] }
      @cases.map { |c| c.dup.tap { |copy| copy.result = by_id[c.id] } }
    end
  end
end
