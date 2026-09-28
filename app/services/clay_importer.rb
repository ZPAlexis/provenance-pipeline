require "csv"

# Imports Clay job-source exports into companies + postings.
#
# Handles two CSV shapes from the same tool: the free sourcing pulls carry
# 7 columns, while pulls that were run through the research agent carry ~28.
# Anything not explicitly mapped is preserved in `enrichment` JSONB rather than
# dropped, so upstream schema changes never lose data. The research agent's
# output stays on the posting its run checked; the company keeps provider
# enrichment, set once and never overwritten.
#
# Every write is recorded in audit_events — creates and updates alike, with
# before/after values — under the importer's own actor identity. Provenance is
# not retrofitted later. Each row is atomic: it lands completely, audit events
# included, or not at all.
class ClayImporter
  ACTOR = "agent:clay_importer".freeze

  CORE_COLUMNS = {
    "Company Name"     => :company_name,
    "Job Title"        => :role_title,
    "Location"         => :location,
    "Company Domain"   => :domain,
    "Job LinkedIn URL" => :posting_url,
    "Posted On"        => :posted_on
  }.freeze

  RESEARCH_COLUMNS = {
    "Career Search Prospecting Researcher Posting Verified"    => :verification_state,
    "Career Search Prospecting Researcher Roles Listed Count"  => :roles_listed_count,
    "Career Search Prospecting Researcher Work Mode"           => :work_mode,
    "Career Search Prospecting Researcher Careers Page Url"    => :careers_page_url,
    "Career Search Prospecting Researcher Reasoning"           => :reasoning,
    "Career Search Prospecting Researcher Hiring Evidence"     => :hiring_evidence,
    "Career Search Prospecting Researcher Verified Role Title" => :verified_role_title
  }.freeze

  # Every column the research agent produces starts with this. Each run is an
  # observation made while checking one posting — even answers about the
  # employer, like Industry — and two runs at the same employer can disagree.
  # Merged onto the company, re-imports would flip between their answers and
  # log churn as real changes; on the posting, both survive beside their
  # reasoning. Matching by prefix keeps new researcher fields there too.
  RESEARCH_OUTPUT_PREFIX = "Career Search".freeze

  DATE_ONLY = /\A\d{4}-\d{2}-\d{2}\z/

  Result = Struct.new(
    :rows, :companies_created, :companies_matched,
    :postings_created, :postings_skipped, :verdicts_undated, :errors,
    keyword_init: true
  ) do
    def to_s
      "rows=#{rows} companies(new=#{companies_created} matched=#{companies_matched}) " \
        "postings(new=#{postings_created} skipped=#{postings_skipped}) errors=#{errors.size}"
    end
  end

  # `verified_at` is when the export's verdicts were reached. Clay exports carry
  # no per-row verification date, so whoever runs the import supplies it;
  # without one, last_checked_at stays nil (unknown) rather than being guessed.
  def self.call(path, slice: nil, verified_at: nil)
    new(path, slice: slice, verified_at: verified_at).call
  end

  # Import every CSV in a directory.
  def self.import_dir(dir, verified_at: nil)
    Pathname.glob(Pathname.new(dir).join("*.csv")).sort.map do |path|
      [ path.basename.to_s, call(path, verified_at: verified_at) ]
    end
  end

  def initialize(path, slice: nil, verified_at: nil)
    @path        = Pathname.new(path)
    @slice       = slice || derive_slice(@path)
    @verified_at = parse_verified_at(verified_at)
    @result      = Result.new(
      rows: 0, companies_created: 0, companies_matched: 0,
      postings_created: 0, postings_skipped: 0, verdicts_undated: 0, errors: []
    )
  end

  def call
    CSV.foreach(@path, headers: true, encoding: "bom|utf-8") do |csv_row|
      @result.rows += 1
      outcome = import_row(csv_row.to_h)
      tally(outcome) if outcome
    rescue => e
      @result.errors << { row: @result.rows, error: e.message }
    end

    @result
  end

  private

  # "GTM-Brazil-export-1790189191374.csv" -> "brazil"; "Testland.csv" -> "testland"
  def derive_slice(path)
    path.basename(path.extname).to_s.split("-export").first.to_s.split("-").last.to_s.downcase.presence || "unknown"
  end

  # ISO 8601 only: this value becomes provenance, so nothing fuzzy is accepted.
  # A bare date is pinned to noon UTC, which falls on the same calendar day in
  # every time zone from UTC-11 to UTC+11.
  def parse_verified_at(value)
    case value
    when nil then nil
    when Time, DateTime, ActiveSupport::TimeWithZone then value
    when Date then noon_utc(value)
    else
      text = value.to_s.strip
      if text.empty? then nil
      elsif text.match?(DATE_ONLY) then noon_utc(Date.iso8601(text))
      else Time.iso8601(text)
      end
    end
  end

  def noon_utc(date)
    Time.utc(date.year, date.month, date.day, 12)
  end

  # Returns what happened to the row's company and posting, or nil for a
  # skipped row. Counted by the caller only once the row has committed, so a
  # rolled-back row counts nothing.
  def import_row(raw)
    core = extract(raw, CORE_COLUMNS)
    return if core[:company_name].blank?

    research = extract(raw, RESEARCH_COLUMNS)
    unmapped = raw.except(*CORE_COLUMNS.keys, *RESEARCH_COLUMNS.keys).compact_blank
    research_output, company_columns = unmapped.partition { |header, _| header.start_with?(RESEARCH_OUTPUT_PREFIX) }.map(&:to_h)

    ApplicationRecord.transaction(requires_new: true) do
      company, company_outcome = upsert_company(core, research, company_columns)
      posting = upsert_posting(company, core, research, research_output)

      {
        company: company_outcome,
        posting: posting ? :created : :skipped,
        undated: posting.present? && verdict?(research) && posting.last_checked_at.nil?
      }
    end
  end

  # Outcomes are named after the Result counters they increment.
  def tally(outcome)
    @result[:"companies_#{outcome[:company]}"] += 1
    @result[:"postings_#{outcome[:posting]}"] += 1
    @result.verdicts_undated += 1 if outcome[:undated]
  end

  def extract(raw, mapping)
    mapping.each_with_object({}) do |(header, key), acc|
      value = raw[header]
      acc[key] = value.is_a?(String) ? value.strip.presence : value
    end
  end

  def verdict?(research)
    research[:verification_state].present?
  end

  # Sets everything on the company first and saves once, so each write is one
  # audit event: a create carrying everything it set, or an update carrying
  # before/after for what changed. An unchanged match writes nothing.
  #
  # Company facts are set once and never overwritten, so re-reading an export
  # is idempotent whatever order rows arrive in. Refreshing them is the
  # enrichment agent's job (companies:enrich), under its own audit trail.
  def upsert_company(core, research, columns)
    company = Company.find_or_initialize_for(name: core[:company_name], domain: core[:domain])
    created = company.new_record?

    # Careers page URL only arrives on research-enriched rows. It is the input
    # the verifier builds on, so it is promoted to the company; each run's own
    # observation is also kept on its posting.
    if research[:careers_page_url].present? && company.careers_page_url.blank?
      company.careers_page_url = research[:careers_page_url]
    end
    company.enrichment = company.enrichment.reverse_merge(columns)

    if company.changed?
      company.save!
      AuditEvent.record_write!(
        company, actor: ACTOR,
        reasoning: "#{created ? 'Created' : 'Updated'} from Clay export #{@path.basename} (slice: #{@slice})."
      )
    end

    [ company, created ? :created : :matched ]
  end

  # Returns the new posting, or nil when it was already imported.
  def upsert_posting(company, core, research, columns)
    return if core[:posting_url].present? && Posting.exists?(posting_url: core[:posting_url])

    posting = Posting.create!(
      company: company,
      role_title: core[:role_title].presence || "(untitled)",
      location: core[:location],
      posting_url: core[:posting_url],
      posted_on: parse_date(core[:posted_on]),
      source_slice: @slice,
      verification_state: normalize_state(research[:verification_state]),
      roles_listed_count: normalize_count(research[:roles_listed_count]),
      work_mode: normalize_work_mode(research[:work_mode]),
      last_checked_at: (@verified_at if verdict?(research)),
      enrichment: {
        "hiring_evidence"        => research[:hiring_evidence],
        "verified_role_title"    => research[:verified_role_title],
        "careers_page_url"       => research[:careers_page_url],
        "raw_verification"       => research[:verification_state],
        "raw_roles_listed_count" => research[:roles_listed_count]
      }.merge(columns).compact_blank
    )

    AuditEvent.record_write!(
      posting, actor: ACTOR,
      reasoning: research[:reasoning].presence ||
                 "Imported from Clay export #{@path.basename} (slice: #{@slice}). Not yet verified at source."
    )

    posting
  end

  # Unrecognized upstream values fall back to "pending" rather than failing the
  # import; the original is preserved in enrichment["raw_verification"].
  def normalize_state(value)
    v = value.to_s.strip.downcase
    Posting::VERIFICATION_STATES.include?(v) ? v : "pending"
  end

  # Clay emits a negative count as a "could not count" sentinel. Anything that
  # is not a non-negative integer becomes nil (unknown), which the
  # negative-verdict scopes already treat as suspect; the original is preserved
  # in enrichment["raw_roles_listed_count"].
  def normalize_count(value)
    count = Integer(value.to_s.strip, exception: false)
    count if count && count >= 0
  end

  def normalize_work_mode(value)
    v = value.to_s.strip.downcase
    Posting::WORK_MODES.include?(v) ? v : nil
  end

  def parse_date(value)
    return nil if value.blank?
    Date.parse(value.to_s)
  rescue Date::Error
    nil
  end
end
