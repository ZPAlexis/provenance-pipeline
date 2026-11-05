# The companies on the watch list as the Companies page lists them (4a), shared with the operator's own Claude
# client (list_companies, through MCP): those tracked, those archived ("dismissed", the stored word) and all, and
# within them what needs a look, each company's roles in a line.
module WatchList
  TABS = { "tracked" => "Tracked", "dismissed" => "Archived", "all" => "All" }.freeze
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

  module_function

  def in_tab(scope, tab) = tab == "all" ? scope : scope.where(tracking: tab)

  def narrow(scope, filter) = filter ? FILTERS.fetch(filter).last.call(scope) : scope

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
