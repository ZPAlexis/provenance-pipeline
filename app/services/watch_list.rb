# The companies on the watch list as the Companies page lists them (4a), shared with the operator's own Claude
# client (list_companies, through MCP): those tracked, those the client proposed (4b), those archived ("dismissed",
# the stored word) and all, and within them what needs a look, each company's roles in a line; and (4b) each one's
# fit, by its newest company review, with the review's facts to narrow by.
module WatchList
  TABS = { "tracked" => "Tracked", "suggested" => "Suggested", "dismissed" => "Archived", "all" => "All" }.freeze
  # What needs a look within a tab, each with what it holds: no careers page found yet, one found at low confidence
  # to confirm, no role tracked, or roles tracked of which none was still listed at its last check. The last two
  # never overlap: "listed" is a tracked role's answer, as in the roles line.
  FILTERS = {
    "no_page" => [ "No careers page yet", "Never looked for, or none found", lambda { |scope|
      scope.where(resolution_status: [ nil, "failed" ])
    } ],
    "to_confirm" => [ "Page to confirm", "A careers page found at low confidence, held for you to confirm", lambda { |scope|
      scope.resolution_candidates
    } ],
    "none_tracked" => [ "No role tracked", "No role tracked there (a suggestion may be)", lambda { |scope|
      scope.where.not(id: Posting.tracked.select(:company_id))
    } ],
    "none_listed" => [ "None still listed", "Roles tracked there, but none still listed at its last check: gone, or no answer yet", lambda { |scope|
      scope.where(id: Posting.tracked.select(:company_id)).where.not(id: Posting.tracked.live.select(:company_id))
    } ]
  }.freeze
  # Each answer a tracked role can have, as the Roles page says it.
  ANSWERS = { "verified_live" => "still listed", "not_found" => "gone", "pending" => "no answer yet", "inaccessible" => "couldn't confirm" }.freeze
  # The fit a list can be narrowed to (4b), by each company's newest review: at least this score (stale or not, as for
  # roles), none yet, or one read against company preferences or places since changed.
  FITS = { "85" => "85 and up", "70" => "70 and up", "50" => "50 and up", "none" => "Not reviewed", "stale" => "Stale" }.freeze
  # The facts of a newest review a list can be narrowed to (4b), in the preferences' own values: its stage, size and
  # business model, one of its industries, one of the regions it operates and hires in.
  FACTS = { "stage" => "Stage", "size" => "Size", "model" => "Business model", "industry" => "Industry", "region" => "Region" }.freeze
  # An industry or a region a review names, whatever its case.
  HOLDS = { "industry" => "EXISTS (SELECT 1 FROM unnest(company_reviews.industries) AS said WHERE lower(said) = lower(?))",
            "region" => "EXISTS (SELECT 1 FROM unnest(company_reviews.regions) AS said WHERE lower(said) = lower(?))" }.freeze

  module_function

  def in_tab(scope, tab) = tab == "all" ? scope : scope.where(tracking: tab)

  def narrow(scope, filter) = filter ? FILTERS.fetch(filter).last.call(scope) : scope

  # Each company's newest review, as a relation named company_reviews.
  def newest_reviews
    CompanyReview.from(CompanyReview.select("DISTINCT ON (company_id) company_reviews.*").order(:company_id, created_at: :desc), :company_reviews)
  end

  # The newest review of each company given, { company_id => review }.
  def reviews(ids) = newest_reviews.where(company_id: ids).index_by(&:company_id)

  # `scope` narrowed to a fit (a FITS key; nil for any), stale against `profile`'s preferences and places as they are.
  def by_fit(scope, fit, profile: SearchProfile.current)
    case fit
    when nil then scope
    when "none" then scope.where.not(id: CompanyReview.select(:company_id))
    when "stale" then scope.where(id: newest_reviews.where.not(preferences_digest: profile&.company_preferences_digest.to_s).select(:company_id))
    else scope.where(id: newest_reviews.where(score: Integer(fit)..).select(:company_id))
    end
  end

  # How many companies of `scope` each fit holds.
  def fit_counts(scope, profile: SearchProfile.current) = FITS.keys.to_h { |fit| [ fit, by_fit(scope, fit, profile: profile).count ] }

  # `scope` narrowed to companies whose newest review found these facts ({ FACTS key => value }; an industry or a
  # region matched whatever its case).
  def by_facts(scope, facts)
    facts = facts.to_h.transform_keys(&:to_s).slice(*FACTS.keys).transform_values { |value| value.to_s.strip }.compact_blank
    return scope if facts.empty?

    found = newest_reviews
    found = found.where(stage: facts["stage"]) if facts["stage"]
    found = found.where(size: facts["size"]) if facts["size"]
    found = found.where(business_model: facts["model"]) if facts["model"]
    found = found.where(HOLDS.fetch("industry"), facts["industry"]) if facts["industry"]
    found = found.where(HOLDS.fetch("region"), facts["region"]) if facts["region"]
    scope.where(id: found.select(:company_id))
  end

  # The facts the newest reviews found, to narrow by: { FACTS key => [[label, value]] }, the lists' own values in
  # their order, an industry or a region once whatever its case (capitalized where any spelling is). Empty while none
  # is reviewed.
  def fact_options
    newest = newest_reviews.to_a
    found = ->(field) { newest.filter_map(&field).uniq }
    listed = ->(known, field) { known.select { |value, _| found.call(field).include?(value) }.map { |value, label| [ label, value ] } }
    words = ->(field) { newest.flat_map(&field).sort.uniq(&:downcase).sort_by(&:downcase).map { |word| [ word, word ] } }
    { "stage" => listed.call(SearchProfile::COMPANY_STAGES, :stage),
      "size" => listed.call(SearchProfile::COMPANY_SIZES.to_h { |size| [ size, "#{size} people" ] }, :size),
      "model" => listed.call(SearchProfile::COMPANY_MODELS, :business_model),
      "industry" => words.call(:industries), "region" => words.call(:regions) }.reject { |_, options| options.empty? }
  end

  # How many companies each tab holds, and each filter within `tab`.
  def counts(scope, tab)
    tabbed = in_tab(scope, tab)
    [ TABS.keys.to_h { |each| [ each, in_tab(scope, each).count ] }, FILTERS.transform_values { |(*, narrowed)| narrowed.call(tabbed).count } ]
  end

  # Per company: its roles by tracking and answer, { [company_id, tracking, answer] => n }.
  def role_counts(ids) = Posting.where(company_id: ids).group(:company_id, :tracking, :verification_state).count

  # Its open application, else its latest, per company.
  def applications(ids)
    Application.where(company_id: ids).includes(:posting).order(:stage_changed_on).group_by(&:company_id)
               .transform_values { |list| list.select(&:open?).last || list.last }
  end

  def last_checked(ids) = PageCheck.where(purpose: "verification", company_id: ids).group(:company_id).maximum(:checked_at)

  # A company's roles in a line, as [head, detail]: tracked and suggested ("2 tracked, 1 suggested"), then its
  # tracked roles by their answer at the last check, and how many are archived ("1 still listed · 1 gone · 1
  # archived"). Either may be empty.
  def roles_line(company_id, counts)
    mine = counts.filter_map { |(id, tracking, answer), n| [ tracking, answer, n ] if id == company_id }
    total = ->(&keep) { mine.sum { |tracking, answer, n| keep.call(tracking, answer) ? n : 0 } }
    tracked = total.call { |tracking, _| tracking == "tracked" }
    suggested = total.call { |tracking, _| tracking == "suggested" }
    archived = total.call { |tracking, _| tracking == "dismissed" }
    head = [ ("#{tracked} tracked" if tracked.positive?), ("#{suggested} suggested" if suggested.positive?) ].compact.join(", ")
    answers = ANSWERS.filter_map do |answer, said|
      n = total.call { |tracking, its| tracking == "tracked" && its == answer }
      "#{n} #{said}" if n.positive?
    end
    [ head, (answers + [ ("#{archived} archived" if archived.positive?) ].compact).join(" · ") ]
  end
end
