module Verifier
  # Test A: can the renderer extract listings at all?
  #
  # Measured against every careers page with ground truth: the roles count a
  # research run recorded for it. Page structure barely changes while
  # individual postings come and go, so this test decays slowly. It runs
  # locally only; the pages are a private target list.
  #
  # Passes when every measured page yields at least one listing (including
  # pages where the recorded count was 0, the known parse failures) and, where a
  # count was recorded, the extracted count is within 25% or 3 of it on at least
  # 80% of pages. Counts drift, so a page outside that range is investigated by
  # hand, never failed automatically.
  #
  # A page robots.txt keeps us off is not measured: it says nothing about the
  # renderer. It is reported separately. When its listings were read from the
  # company's ATS board instead, it is measured like any other page.
  class TestA
    TOLERANCE_SHARE = 0.25
    TOLERANCE_FLOOR = 3
    REQUIRED_AGREEMENT = 0.8

    Page = Struct.new(:id, :company, :domain, :url, :recorded, :result, keyword_init: true) do
      def extracted = result && result["listing_count"]

      # Shown alongside for comparison: a role posted in several locations is
      # one title but several listings, and a paginated board states a total
      # larger than the listings on its first page.
      def distinct_titles = result && Array(result["listings"]).map { |listing| listing["title"] }.uniq.size

      def stated_total = result && result["stated_total"]

      def blocked? = result&.dig("outcome") == "blocked"

      # robots.txt kept us off the page, and its listings came from the company's ATS board.
      def ats_fallback? = result&.dig("reason").to_s.end_with?("_ats_fallback")

      def yielded? = result&.dig("outcome") == "ok" && extracted.to_i.positive?

      # The recorded 0s: the page was reached and read as empty, almost certainly a parse failure.
      def known_failure? = recorded&.zero?

      def comparable? = recorded.to_i.positive?

      def within_tolerance?
        comparable? && !extracted.nil? && (extracted - recorded).abs <= [ recorded * TOLERANCE_SHARE, TOLERANCE_FLOOR ].max
      end

      # The page itself says there are no openings: a closed page, not a renderer failure.
      def says_no_openings? = result&.dig("explicit_no_openings") == true
    end

    Report = Struct.new(:pages, keyword_init: true) do
      def blocked = pages.select(&:blocked?)

      def measured = pages.reject(&:blocked?)

      def yielding = measured.count(&:yielded?)

      def comparable = measured.select(&:comparable?)

      def agreeing = comparable.count(&:within_tolerance?)

      def agreement = comparable.empty? ? 1.0 : agreeing.fdiv(comparable.size)

      def known_failures = measured.select(&:known_failure?)

      def passed? = measured.any? && yielding == measured.size && agreement >= REQUIRED_AGREEMENT

      def llm_usages = pages.filter_map { |page| page.result&.dig("llm") }

      def cost_usd = llm_usages.sum { |llm| llm["cost_usd"].to_f }.round(4)

      def tokens = llm_usages.sum { |llm| llm["input_tokens"].to_i + llm["output_tokens"].to_i }
    end

    def initialize(companies = Company.with_careers_page.includes(:postings))
      @pages = companies.map do |company|
        Page.new(id: company.id, company: company.name, domain: company.domain, url: company.careers_page_url,
                 recorded: recorded_count(company))
      end
    end

    # Domain and name let the worker find a company's ATS board when robots.txt
    # keeps it off the careers page.
    def targets
      @pages.map { |page| { id: page.id, url: page.url, label: page.company, domain: page.domain, name: page.company } }
    end

    def evaluate(results)
      by_id = results.index_by { |result| result["target_id"] }
      Report.new(pages: @pages.map { |page| page.dup.tap { |copy| copy.result = by_id[page.id] } })
    end

    private

    # What the research run recorded for this company's page. Several postings
    # at one employer were checked against the same page, so take the largest.
    def recorded_count(company)
      company.postings.select(&:verdict?).filter_map(&:roles_listed_count).max
    end
  end
end
