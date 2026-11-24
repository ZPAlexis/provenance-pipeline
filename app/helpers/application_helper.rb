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

    { "verifier" => "Verifier", "clay_importer" => "Clay import" }.fetch(name.to_s, name.to_s.humanize)
  end

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
    elsif event.action == "destroy"
      changes.dig("tracking", 0) == "suggested" ? "withdrawn" : "deleted"
    elsif event.action == "create" && changes.dig("tracking", 1) == "suggested"
      "suggested"
    elsif (state = changes["verification_state"])
      "#{answer_label(state.first || 'pending')} → #{answer_label(state.last)}"
    elsif (tracking = changes["tracking"])
      "#{tracking.first || 'new'} → #{tracking.last}"
    elsif (url = changes["job_url"])
      url.first ? "own page moved" : "own page learned"
    elsif changes.key?("fit")
      "reasons updated"
    else
      event.action == "create" ? "created" : changes.keys.join(", ")
    end
  end

  # Who wrote it, and the credential its run held when an agent did (1.3).
  def actor_cell(event)
    label = actor_label(event.actor)
    return label unless event.credential

    safe_join([ label, tag.div(link_to("its credential", agent_credential_path(event.credential), title: event.credential.purpose),
                               class: "small") ])
  end

  def nav_link(label, path, current:)
    link_to(label, path, class: ("current" if current))
  end

  # Tabs inside a page (4e), inside an element with data-controller="tabs": `tabs` is [[id, label], ...], the first
  # open. Each panel's id is the anchor links into the page already use, so a link to #links opens the tab holding it.
  def page_tabs(tabs, label:)
    tag.nav(class: "tabs page-tabs", role: "tablist", "aria-label": label) do
      safe_join(tabs.each_with_index.map do |(id, text), index|
        link_to(text, "##{id}", id: "#{id}-tab", role: "tab", "aria-controls": id, "aria-selected": index.zero?,
                                tabindex: (index.zero? ? 0 : -1), class: ("current" if index.zero?),
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
