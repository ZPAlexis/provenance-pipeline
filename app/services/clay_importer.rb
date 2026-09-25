require "csv"

# Imports Clay job-source exports into companies + postings.
#
# Handles two CSV shapes from the same tool: the free sourcing pulls carry
# 7 columns, while pulls that were run through the research agent carry ~28.
# Anything not explicitly mapped is preserved in the `enrichment` JSONB column
# rather than dropped, so upstream schema changes never lose data.
#
# Every write is recorded in audit_events. The importer is treated as an agent
# with its own actor identity from the first row loaded — provenance is not
# retrofitted later.
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

  Result = Struct.new(
    :rows, :companies_created, :companies_matched,
    :postings_created, :postings_skipped, :errors,
    keyword_init: true
  ) do
    def to_s
      "rows=#{rows} companies(new=#{companies_created} matched=#{companies_matched}) " \
        "postings(new=#{postings_created} skipped=#{postings_skipped}) errors=#{errors.size}"
    end
  end

  def self.call(path, slice: nil)
    new(path, slice: slice).call
  end

  # Import every CSV in a directory.
  def self.import_dir(dir)
    Pathname.glob(Pathname.new(dir).join("*.csv")).sort.map do |path|
      [ path.basename.to_s, call(path) ]
    end
  end

  def initialize(path, slice: nil)
    @path   = Pathname.new(path)
    @slice  = slice || derive_slice(@path)
    @result = Result.new(
      rows: 0, companies_created: 0, companies_matched: 0,
      postings_created: 0, postings_skipped: 0, errors: []
    )
  end

  def call
    CSV.foreach(@path, headers: true, encoding: "bom|utf-8") do |csv_row|
      @result.rows += 1
      import_row(csv_row.to_h)
    rescue => e
      @result.errors << { row: @result.rows, error: e.message }
    end

    @result
  end

  private

  # "GTM-Brazil-export-1790189191374.csv" -> "brazil"
  def derive_slice(path)
    path.basename.to_s.split("-export").first.to_s.split("-").last.to_s.downcase.presence || "unknown"
  end

  def import_row(raw)
    core = extract(raw, CORE_COLUMNS)
    return if core[:company_name].blank?

    research = extract(raw, RESEARCH_COLUMNS)
    leftover = raw.except(*(CORE_COLUMNS.keys + RESEARCH_COLUMNS.keys)).compact_blank

    company = upsert_company(core, research, leftover)
    upsert_posting(company, core, research)
  end

  def extract(raw, mapping)
    mapping.each_with_object({}) do |(header, key), acc|
      value = raw[header]
      acc[key] = value.is_a?(String) ? value.strip.presence : value
    end
  end

  def upsert_company(core, research, leftover)
    existed = Company.exists?(domain: core[:domain].to_s.downcase.presence) if core[:domain].present?

    company = Company.find_or_create_for!(name: core[:company_name], domain: core[:domain])

    if existed
      @result.companies_matched += 1
    else
      @result.companies_created += 1
      AuditEvent.record!(
        actor: ACTOR, action: "create", target: company,
        changes_made: { name: company.name, domain: company.domain },
        reasoning: "Created from Clay export #{@path.basename} (slice: #{@slice})."
      )
    end

    # Careers page URL only arrives on research-enriched rows; never overwrite
    # a known value with nil.
    updates = {}
    updates[:careers_page_url] = research[:careers_page_url] if research[:careers_page_url].present? && company.careers_page_url.blank?

    merged = company.enrichment.merge(leftover)
    updates[:enrichment] = merged if merged != company.enrichment

    company.update!(updates) if updates.any?
    company
  end

  def upsert_posting(company, core, research)
    if core[:posting_url].present? && Posting.exists?(posting_url: core[:posting_url])
      @result.postings_skipped += 1
      return
    end

    posting = Posting.create!(
      company: company,
      role_title: core[:role_title].presence || "(untitled)",
      location: core[:location],
      posting_url: core[:posting_url],
      posted_on: parse_date(core[:posted_on]),
      source_slice: @slice,
      verification_state: normalize_state(research[:verification_state]),
      roles_listed_count: research[:roles_listed_count].presence&.to_i,
      work_mode: normalize_work_mode(research[:work_mode]),
      last_checked_at: research[:verification_state].present? ? File.mtime(@path) : nil,
      enrichment: {
        "hiring_evidence"     => research[:hiring_evidence],
        "verified_role_title" => research[:verified_role_title],
        "raw_verification"    => research[:verification_state]
      }.compact_blank
    )

    @result.postings_created += 1

    AuditEvent.record!(
      actor: ACTOR, action: "create", target: posting,
      changes_made: { role_title: posting.role_title, verification_state: posting.verification_state },
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
