module Verifier
  # Each role's description (Stage 2b), read from its own page by the worker's
  # `describe` (its board's job API, or the page rendered; never the LLM), and
  # kept as versions: the same text again only says when it was seen, a changed
  # one is a new version. Written as the verifier, under a credential for the
  # read with `evidence:write` alone: a description is evidence of what a page
  # said, and changes nothing about the role.
  module Descriptions
    SCOPES = %w[evidence:write].freeze

    # What one role's read found, in a sentence: what is shown and said. Answers a
    # check run as a check's outcome does (CheckNowJob): read or not, and free.
    Read = Data.define(:posting, :outcome, :summary, :version, :new_version) do
      def finished? = outcome != "error"

      def answer = outcome == "ok" ? "read" : outcome

      def tally = {}

      def cost_usd = 0.0

      def run_id = version&.run_id
    end

    module_function

    def target(posting) = { id: posting.id, url: posting.job_url, label: "#{posting.company.name} / #{posting.role_title}" }

    # Reads `postings`' descriptions in one run; a role with no page of its own is said so without one.
    def read!(postings, purpose:, worker: Worker.new(run_dir: Worker.dir_for("describe")), issued_by: AuditEvent::OPERATOR)
      postings = Array(postings)
      without, with = postings.partition { |posting| posting.job_url.blank? }
      reads = without.map { |posting| Read.new(posting:, outcome: "no_page", summary: NO_PAGE, version: nil, new_version: false) }
      return reads if with.empty?

      Authority.run(Ingest::ACTOR, scopes: SCOPES, purpose: purpose, ttl: with.one? ? Authority::ONE : Authority::BATCH,
                                   issued_by: issued_by) do
        run = worker.run(with.map { |posting| target(posting) }, command: "describe")
        by_id = with.index_by(&:id)
        run.results.each do |result|
          reads << record(result, by_id, run.id)
        rescue Ingest::InvalidResult => e # one result that breaks the contract never stops the rest
          posting = by_id[result.try(:[], "target_id")] or next
          reads << Read.new(posting:, outcome: "error", summary: "Not recorded: #{e.message}", version: nil, new_version: false)
        end
        missing = with - reads.map(&:posting)
        reads += missing.map { |posting| Read.new(posting:, outcome: "error", summary: stopped(run), version: nil, new_version: false) }
      end
      reads
    end

    # What `peek` read: each page's result by its id, and the run's id.
    Peek = Data.define(:results, :run_id)

    # What each of `pages` ({ id:, url:, label: }) says now, read as `read!` reads (free, never the LLM) but keeping
    # nothing: for roles not on record yet (2f step 3), so the client suggests only the ones whose own page still has
    # them. Each result goes through the contract; one that breaks it, or is missing, reads as an error.
    def peek(pages, worker: Worker.new(run_dir: Worker.dir_for("describe")))
      return Peek.new(results: {}, run_id: nil) if pages.empty?

      run = worker.run(pages, command: "describe")
      by_id = run.results.select { |result| result.is_a?(Hash) }.index_by { |result| result["target_id"] }
      results = pages.to_h do |page|
        result = by_id[page[:id]]
        errors = result ? ResultContract.description_errors(result) : [ run.stopped ? "stopped: #{run.stopped}" : "no result written" ]
        [ page[:id], errors.empty? ? result : { "outcome" => "error", "reason" => errors.join("; ") } ]
      end
      Peek.new(results: results, run_id: run.id)
    end

    # Descriptions `peek` read, kept for the roles now on record from them ([[posting, result]]), as `read!` keeps
    # them: under the verifier's credential with evidence:write alone, issued by the operator.
    def keep!(pairs, run_id:, purpose:, issued_by: AuditEvent::OPERATOR)
      return [] if pairs.empty?

      Authority.run(Ingest::ACTOR, scopes: SCOPES, purpose: purpose, ttl: pairs.one? ? Authority::ONE : Authority::BATCH, issued_by: issued_by) do
        pairs.map { |posting, result| record(result.merge("target_id" => posting.id), { posting.id => posting }, run_id) }
      end
    end

    NO_PAGE = "No page of its own on record: add its link to read its description.".freeze

    # One result through the contract, then kept: a new version, or the same text seen again.
    def record(result, by_id, run_id)
      errors = ResultContract.description_errors(result)
      posting = by_id[result.try(:[], "target_id")]
      raise Ingest::InvalidResult, "#{result.try(:[], 'target_id') || '(no target)'}: #{errors.join('; ')}" if errors.any?
      raise Ingest::InvalidResult, "#{result['target_id']}: not a role asked for" unless posting
      return Read.new(posting:, outcome: result["outcome"], summary: why_not(result), version: nil, new_version: false) unless result["outcome"] == "ok"

      at = Time.iso8601(result["checked_at"])
      latest = posting.role_descriptions.newest_first.first
      if latest&.content_hash == result["content_hash"]
        latest.update!(last_read_at: at)
        return Read.new(posting:, outcome: "ok", summary: "Read again: the same text as on #{latest.first_read_at.to_date}.",
                        version: latest, new_version: false)
      end

      version = posting.role_descriptions.create!(
        text: result["text"], content_hash: result["content_hash"], read_via: result["read_via"], url: result["url"],
        run_id: run_id, first_read_at: at, last_read_at: at
      )
      lead = latest ? "Changed since it was read on #{latest.first_read_at.to_date}" : "Read"
      cut = " (cut at the limit)" if result["reason"] == "cut_at_limit"
      Read.new(posting:, outcome: "ok", new_version: true, version: version,
               summary: "#{lead}: #{version.words} words through #{version.read_through}#{cut}.")
    end

    WHY_NOT = {
      "gone" => "Its board or its page no longer has it (%s).", "blocked" => "Its robots.txt keeps us off its page.",
      "inaccessible" => "Its page could not be read (%s).", "no_page" => NO_PAGE, "error" => "The read failed (%s)."
    }.freeze

    def why_not(result)
      said = WHY_NOT.fetch(result["outcome"])
      said.include?("%s") ? format(said, result["reason"]) : said
    end

    def stopped(run) = "Stopped before it was read: #{run.stopped || 'no result written'}."
  end
end
