module ApplicationHelper
  # Each answer's colour; the words are Posting::ANSWER_LABELS.
  ANSWER_TONES = { "verified_live" => "live", "not_found" => "gone", "inaccessible" => "unsure", "pending" => "idle" }.freeze

  READ_VIA = {
    "render+llm" => "read by the LLM",
    "reused" => "earlier read reused",
    "render" => "loaded, not read by the LLM"
  }.freeze

  def answer_label(state) = Posting::ANSWER_LABELS.fetch(state, state.to_s.humanize)

  def answer_tone(state) = ANSWER_TONES.fetch(state, "idle")

  def answer_badge(state) = tag.span(answer_label(state), class: [ "badge", answer_tone(state) ])

  # A fit score (2f) as a badge: green from 70, amber from 50, plain below.
  def fit_badge(score)
    tag.span(score, class: [ "badge", "fit", ("live" if score >= 70), ("unsure" if score.between?(50, 69)) ], title: "Fit, out of 100")
  end

  # A role's newest fit in a table cell: its badge, marked when the resume or its description changed since, and (4d)
  # when a must-have isn't on the resume: a screen risk, saying what and whether it capped the score.
  def fit_cell(shown)
    return tag.span("—", class: "muted", title: "Not weighed yet") unless shown

    score = shown.score
    risks = score.screen_risks.map { |must| must["asks"] }
    safe_join([ fit_badge(score.score),
                (tag.span(" screen risk", class: "small warn",
                          title: "Not on the resume: #{risks.to_sentence}#{". Capped from #{score.score_before_cap}" if score.capped?}") if risks.any?),
                (tag.span(" stale", class: "muted small", title: "#{shown.stale.to_sentence.upcase_first} changed since") if shown.stale?) ])
  end

  # A finished check run's answer: the role's verdict, or that a company was checked.
  def run_answer(run)
    return tag.span(run.answer == "weighed" ? "Weighed" : "Not weighed", class: [ "badge", run.answer == "weighed" ? "live" : "unsure" ]) if run.kind == "fit"
    return tag.span(run.answer == "read" ? "Read" : "Not read", class: [ "badge", run.answer == "read" ? "live" : "unsure" ]) if run.kind.in?(%w[describe links])
    return tag.span(run.answer == "drafted" ? "Drafted" : "Not drafted", class: [ "badge", run.answer == "drafted" ? "live" : "unsure" ]) if run.kind == "draft"
    return tag.span(run.answer == "reviewed" ? "Reviewed" : "Not reviewed", class: [ "badge", run.answer == "reviewed" ? "live" : "unsure" ]) if run.kind == "review"
    return tag.span("Checked", class: "badge live") if run.kind != "role"

    run.answer ? answer_badge(run.answer) : tag.span("Couldn't confirm", class: "badge unsure")
  end

  # A role's or a company's tracking, in the operator's words (4a): "dismissed" is stored, "archived" is said.
  def tracking_label(tracking) = Verifier::Tracking.label(tracking)

  def tracking_badge(tracking)
    tag.span(tracking_label(tracking), class: [ "badge", ("live" if tracking == "tracked") ])
  end

  # Who wrote something: the operator (any human, including rows from before
  # the operator was named that), or an agent by its role.
  def actor_label(actor)
    kind, name = actor.to_s.split(":", 2)
    return "Operator" if kind == "human"

    { "verifier" => "Verifier", "clay_importer" => "Clay import", "assistant" => "AI assistant" }.fetch(name.to_s, name.to_s.humanize)
  end

  # The same in a sentence ("issued to the verifier", "to the AI assistant").
  def actor_label_inline(actor)
    label = actor_label(actor)
    label.start_with?("AI ") ? label : label.downcase
  end

  # Who wrote something, by kind, as its badge is colored (4e): you, your AI assistant through MCP, the app's own
  # agents, or the system (the review queue's fixed grant).
  def actor_group(actor)
    kind, = actor.to_s.split(":", 2)
    return "you" if kind == "human" || actor.to_s == "operator"
    return "assistant" if actor.to_s == "agent:assistant"
    return "system" if kind == "system"

    "agent"
  end

  def actor_badge(actor) = tag.span(actor_label(actor), class: [ "badge", "by-#{actor_group(actor)}" ], title: actor)

  # A dot of the same color, beside a name in a tab or a chip.
  def actor_dot(actor) = tag.span(class: [ "dot", "by-#{actor_group(actor)}" ], "aria-hidden": true)

  def read_via_label(read_via)
    return "—" if read_via.blank?
    return "#{read_via.delete_prefix('ats_api:').capitalize} API" if read_via.start_with?("ats_api:")

    READ_VIA.fetch(read_via, read_via)
  end

  # "3 days ago", with the exact time on hover; "never" for nil.
  def ago(time)
    return tag.span("never", class: "muted") if time.nil?

    tag.time("#{time_ago_in_words(time)} ago", datetime: time.utc.iso8601, title: time.utc.strftime("%Y-%m-%d %H:%M UTC"),
                                               class: "nowrap")
  end

  # What a check could cost, said as surely as the record knows it (4e): "at most $0.02" once its page was read in full
  # (or is read through a free board), "about $0.03" for a page never read, priced at an average list. A check of all
  # tracked companies on 2026-11-24 asked "at most $0.15" and spent $0.28: one list never read cost nine times one call.
  def check_cost(amount, record = nil, known: Verifier::CheckNow.known_cost?(record))
    "#{known ? 'at most' : 'about'} #{cost(amount)}"
  end

  # How long ago, in the fewest characters, for a list's narrow column (4e): "3d", "5w", "2mo"; in full on hover.
  def short_ago(time)
    return tag.span("never", class: "muted") if time.nil?

    seconds = Time.current - time
    text = if seconds < 1.hour then "now"
    elsif seconds < 1.day then "#{(seconds / 1.hour).floor}h"
    elsif seconds < 14.days then "#{(seconds / 1.day).floor}d"
    elsif seconds < 60.days then "#{(seconds / 1.week).floor}w"
    elsif seconds < 1.year then "#{(seconds / 30.days).floor}mo"
    else "#{(seconds / 1.year).floor}y"
    end
    tag.time(text, datetime: time.utc.iso8601, title: "#{time_ago_in_words(time)} ago, #{time.utc.strftime('%Y-%m-%d %H:%M UTC')}",
                   class: "nowrap")
  end

  # A page's link in a list's narrow column (4e): its site in two words ("greenhouse.io", "acme.com"), the address on hover.
  def short_link(url)
    return tag.span("—", class: "muted") if url.blank?

    host = URI.parse(url).host.to_s
    return url if host.empty?

    link_to("#{host.split('.').last(2).join('.')} ↗", url, target: "_blank", rel: "noopener noreferrer", title: url, class: "nowrap")
  rescue URI::InvalidURIError
    url
  end

  # An outside address, shown short: its host and path (or its host alone), opened in a new tab.
  def outside_link(url, label: nil, host_only: false)
    return tag.span("—", class: "muted") if url.blank?

    uri = URI.parse(url)
    # Addresses come from the pages read: only a web address is ever a link.
    return url unless uri.is_a?(URI::HTTP) && uri.host.present?

    host = uri.host.to_s.delete_prefix("www.")
    text = label || (host_only ? host : [ host, uri.path.to_s.chomp("/") ].join.truncate(60))
    link_to(text, url, target: "_blank", rel: "noopener noreferrer", title: url)
  rescue URI::InvalidURIError
    url
  end

  # How a company's careers page is read: a free board in its place, a known ATS, or its own site.
  def read_through(company)
    return "#{company.board_vendor.capitalize} board (free)" if company.board_in_use
    return tag.span("—", class: "muted") if company.ats_type.blank? || company.ats_type == "unknown"

    { "own_site" => "Its own site", "other" => "Another system" }.fetch(company.ats_type, company.ats_type.capitalize)
  end

  def money(amount) = format("$%.2f", amount.to_f)

  # A check's cost: fractions of a cent show, since most checks cost a cent or less.
  def cost(amount)
    amount = amount.to_f
    return "$0" if amount.zero?

    amount < 0.1 ? format("$%.3f", amount) : format("$%.2f", amount)
  end

  # What an audit event changed, in words: a verdict, the watch list, or the fields it set.
  def change_summary(event)
    changes = event.changes_made
    if event.action == "denied"
      safe_join([ tag.span("Refused", class: "badge gone"), (" #{changes.keys.join(', ')}" if changes.any?) ])
    elsif event.target_type == "FitScore"
      fit_change(event)
    elsif (said = application_change(event) || company_record_change(event))
      said
    elsif event.action == "destroy"
      changes.dig("tracking", 0) == "suggested" ? "withdrawn" : "deleted"
    elsif event.action == "create" && changes.dig("tracking", 1) == "suggested"
      "suggested"
    elsif (state = changes["verification_state"])
      "#{answer_label(state.first || 'pending')} → #{answer_label(state.last)}"
    elsif (tracking = changes["tracking"])
      "#{tracking.first ? tracking_label(tracking.first) : 'new'} → #{tracking_label(tracking.last)}"
    elsif (url = changes["job_url"])
      url.first ? "own page moved" : "own page learned"
    elsif changes.key?("fit")
      "reasons updated"
    else
      event.action == "create" ? "created" : changes.keys.join(", ")
    end
  end

  # A fit score's event as a role's history says it (4e): the scores it weighed, never its text.
  def fit_change(event)
    return "fit score deleted" if event.action == "destroy"

    score, background = event.changes_made.values_at("score", "background_score").map { |change| Array(change).last }
    "fit weighed: #{score}#{" (Background fit #{background})" if background}"
  end

  # An event on an application or a record under it (4e), as its history says it: its stage moved, an activity
  # logged, a draft or a resume review written, a contact linked. Nil for any other record.
  def application_change(event)
    changes = event.changes_made
    case event.target_type
    when "Application" then application_stage_change(event.action, changes)
    when "Activity" then { "create" => "logged: #{Array(changes['kind']).compact.last.to_s.humanize.downcase}",
                           "destroy" => "activity deleted" }.fetch(event.action, "activity edited")
    when "Draft"
      label = Draft::LABELS.fetch(Array(changes["kind"]).compact.last, "Draft").downcase
      return "#{label} deleted" if event.action == "destroy"
      return "#{label} written" if event.action == "create"

      Array(changes["status"]).last == "approved" ? "draft approved" : "draft edited"
    when "ResumeReview" then event.action == "destroy" ? "resume review deleted" : "resume review written"
    when "ApplicationContact" then event.action == "destroy" ? "contact unlinked" : "contact linked"
    end
  end

  # An event on a company or a record under it (4e), as its history says it: its careers page found or set, renamed,
  # a review saved, a contact added. Nil for any other record, and for a change the general words say (tracking).
  def company_record_change(event)
    changes = event.changes_made
    case event.target_type
    when "CompanyReview"
      event.action == "destroy" ? "company review deleted" : "company review: #{Array(changes['score']).compact.last}"
    when "Contact" then { "create" => "contact added", "destroy" => "contact deleted" }.fetch(event.action, "contact edited")
    when "Company"
      return if changes.key?("tracking") || event.action == "denied"
      return "added" if event.action == "create"

      status = Array(changes["resolution_status"]).last
      said = [ ("renamed" if changes.key?("name")),
               ({ "resolved" => "careers page found", "candidate" => "a careers page to confirm", "failed" => "careers page not found" }
                  .fetch(status) { "careers page set" } if changes.key?("careers_page_url") || status),
               ("free board" if changes.key?("board_vendor") || changes.key?("board_in_use")),
               ("proposal" if changes.key?("proposal")), ("kind" if changes.key?("kind")) ].compact
      said.any? ? said.join(", ") : nil
    end
  end

  def application_stage_change(action, changes)
    from, to = Array(changes["stage"])
    return "started at #{Application.stage_label(to)}" if action == "create" && to
    return "#{Application.stage_label(from)} → #{Application.stage_label(to)}" if from && to && from != to
    return "redated to #{Array(changes['stage_changed_on']).last}" if changes.key?("stage_changed_on")

    { "notes" => "notes", "comp_expectation" => "pay expectation" }.values_at(*changes.keys).compact.join(", ").presence || "edited"
  end

  # Who wrote it, and the credential its run held when an agent did (1.3).
  def actor_cell(event)
    label = actor_badge(event.actor)
    return label unless event.credential

    safe_join([ label, tag.div(link_to("its credential", agent_credential_path(event.credential), title: event.credential.purpose),
                               class: "small") ])
  end

  def nav_link(label, path, current:)
    link_to(label, path, class: ("current" if current))
  end

  # Tabs inside a page (4e), inside an element with data-controller="tabs": `tabs` is [[id, label], ...], the first
  # open. Each panel's id is the anchor links into the page already use, so a link to #links opens the tab holding it.
  # `current`, a tab's id, opens on another than the first (4e step 11: the audit log's Check results, by address), as
  # its panel's `first:` says too.
  def page_tabs(tabs, label:, current: tabs.first&.first)
    tag.nav(class: "tabs page-tabs", role: "tablist", "aria-label": label) do
      safe_join(tabs.map do |id, text|
        on = id == current
        link_to(text, "##{id}", id: "#{id}-tab", role: "tab", "aria-controls": id, "aria-selected": on,
                                tabindex: (on ? 0 : -1), class: ("current" if on),
                                data: { tabs_target: "tab", action: "tabs#select keydown->tabs#key" })
      end)
    end
  end

  # A tab's panel (4e): hidden until chosen, but the first, so the page shows its first tab before the script runs.
  def tab_panel(id, first: false, &)
    tag.section(id: id, class: "tab-panel", role: "tabpanel", "aria-labelledby": "#{id}-tab", hidden: !first,
                data: { tabs_target: "panel" }, &)
  end

  # What a page or a tab explains beyond its one line (4e), folded until asked for.
  def how_this_works(&)
    tag.details(class: "how") { safe_join([ tag.summary("How this works"), tag.div(class: "how-body", &) ]) }
  end
end
