module Verifier
  # Test B: does the verifier reach the verdict the research did?
  #
  # Every posting Clay's research gave a verdict is matched against its
  # company's watched page, and the verdict is compared with that label. The
  # label is read from what the import recorded (enrichment["raw_verification"]),
  # so it survives the verifier later replacing the posting's verdict.
  #
  # Measured: postings that got a verdict. An inconclusive check (the page
  # showed only part of its list and nothing matched) is reported, not scored,
  # and so is a posting whose company has no watched page yet. An `inaccessible`
  # label says the research could not see the page, not whether the role
  # existed, so it is reported but not scored.
  #
  # Passes when at least 80% of measured postings agree with their label AND
  # no labeled negative comes back verified_live: that would be a closed role
  # reported open. Labels go stale (roles close), so every disagreement is
  # checked by hand; one confirmed stale counts as agreement (decided 2026-10-01).
  # A hand check is recorded with verifier:hand_check, and read back from the
  # posting's history, so it counts in every later run.
  #
  # REPLAY reads the listings stored by an earlier page check, at no API cost.
  # FRESH reads each watched page in full now (every page of its list), which is
  # what the pass is decided on. Read-only either way: the test writes nothing.
  class TestB
    REQUIRED_AGREEMENT = 0.8
    SCORED_LABELS = %w[verified_live not_found].freeze

    Case = Struct.new(:posting_id, :company_id, :company, :title, :location, :label, :result, :snapshot,
                      :watched_url, :domain, :hand_verdict, :aggregator, keyword_init: true) do
      def verdict = result&.dig("verdict")

      def scored_label? = SCORED_LABELS.include?(label)

      def measured? = scored_label? && verdict.present?

      def agrees? = measured? && (verdict == label || verdict == hand_verdict)

      # The label was wrong or went stale, and the operator's own check says so.
      def agrees_by_hand? = agrees? && verdict != label

      # A role the research found closed, reported open: the costly mistake,
      # unless the operator's own check found it open.
      def false_live? = label == "not_found" && verdict == "verified_live" && hand_verdict != "verified_live"

      def why_unmeasured
        return "label #{label}: says nothing about the role" unless scored_label?
        return "an aggregator: its postings belong to other employers" if aggregator
        return "the company has no watched page" unless watched_url
        return "not checked (no stored check of the watched page, in a replay)" unless result

        "inconclusive: #{result['reasoning']}" if verdict.nil?
      end
    end

    Report = Struct.new(:cases, :results, keyword_init: true) do
      def measured = cases.select(&:measured?)

      def unmeasured = cases.reject(&:measured?)

      def agreeing = measured.count(&:agrees?)

      def share = measured.empty? ? 0.0 : agreeing.fdiv(measured.size)

      def disagreements = measured.reject(&:agrees?)

      def false_lives = measured.select(&:false_live?)

      def passed? = measured.any? && share >= REQUIRED_AGREEMENT && false_lives.empty?

      def by_method = measured.map { |c| [ c.result["method"], c.agrees? ] }.tally

      # Extraction on every page read, plus the near-miss call.
      def llm_usages
        results.flat_map do |result|
          Array(result["checks"]).filter_map { |check| check["llm"] } + [ result["llm"], result["match_llm"] ].compact
        end
      end

      def cost_usd = llm_usages.sum { |llm| llm["cost_usd"].to_f }.round(4)

      def tokens = llm_usages.sum { |llm| llm["input_tokens"].to_i + llm["output_tokens"].to_i }
    end

    def self.label_for(posting)
      raw = posting.enrichment["raw_verification"].to_s.strip.downcase
      raw if Posting::VERDICTS.include?(raw)
    end

    # The stored check that read the watched page: by its address, or, for a
    # board watched at its public address, by the board it read.
    def self.snapshot_for(company)
      url = company.careers_page_url or return
      checks = company.page_checks.where(outcome: "ok").order(:checked_at)
      checks.where("url = :url OR final_url = :url", url: url).last ||
        checks.where.not(ats_vendor: nil).to_a.reverse.find { |c| Resolution.board_url(c.ats_vendor, c.ats_board) == url }
    end

    # The whole list was read: through an ATS API, or from a page that says it
    # shows everything. A total the page states settles it, as in resolution.
    def self.complete?(check)
      return true if check.read_via.to_s.start_with?("ats_api")
      return check.listing_count.to_i >= check.stated_total if check.stated_total

      !check.listings_incomplete
    end

    def initialize(postings = Posting.includes(:company))
      @cases = postings.filter_map do |posting|
        label = self.class.label_for(posting) or next
        company = posting.company
        Case.new(posting_id: posting.id, company_id: company.id, company: company.name, title: posting.role_title,
                 location: posting.location, label: label,
                 domain: company.domain, hand_verdict: HandCheck.latest_verdict(posting),
                 aggregator: company.kind == "aggregator",
                 watched_url: (company.careers_page_url if company.resolution_status == "resolved" && company.kind != "aggregator"),
                 snapshot: (self.class.snapshot_for(company) if company.resolution_status == "resolved" && company.kind != "aggregator"))
      end
    end

    # One target per company: its scored postings, and the listings its watched page showed.
    # One target per company with a watched page: the page, and its scored postings.
    # Every posting at the company, labeled or not: only labeled ones are scored,
    # but a passing run's results can then be recorded as they are
    # (verifier:verify RESULTS=), so these pages are never read twice.
    def verify_targets
      ids = @cases.select { |c| c.scored_label? && c.watched_url }.map(&:company_id).uniq
      Company.where(id: ids).includes(:postings).order(:name).map do |company|
        { id: company.id, url: company.careers_page_url, label: company.name, domain: company.domain, name: company.name,
          postings: company.postings.map { |p| { id: p.id, title: p.role_title, location: p.location } } }
      end
    end

    def replay_targets
      @cases.select { |c| c.scored_label? && c.snapshot }.group_by(&:company_id).map do |company_id, cases|
        check = cases.first.snapshot
        { id: company_id, label: cases.first.company, page_check_id: check.id, complete: self.class.complete?(check),
          listings: check.listings,
          postings: cases.map { |c| { id: c.posting_id, title: c.title, location: c.location } } }
      end
    end

    def evaluate(results)
      verdicts = results.flat_map { |result| Array(result["verdicts"]) }.index_by { |verdict| verdict["posting_id"] }
      Report.new(cases: @cases.map { |c| c.dup.tap { |copy| copy.result = verdicts[c.posting_id] } }, results: results)
    end
  end
end
