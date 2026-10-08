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

  # A finished check run's answer: the role's verdict, or that a company was checked.
  def run_answer(run)
    return tag.span("Checked", class: "badge live") if run.kind == "company"

    run.answer ? answer_badge(run.answer) : tag.span("Couldn't confirm", class: "badge unsure")
  end

  def tracking_badge(tracking)
    tag.span(tracking, class: [ "badge", ("live" if tracking == "tracked") ])
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
    if (state = changes["verification_state"])
      "#{answer_label(state.first || 'pending')} → #{answer_label(state.last)}"
    elsif (tracking = changes["tracking"])
      "#{tracking.first || 'new'} → #{tracking.last}"
    elsif (url = changes["job_url"])
      url.first ? "own page moved" : "own page learned"
    else
      event.action == "create" ? "created" : changes.keys.join(", ")
    end
  end

  def nav_link(label, path, current:)
    link_to(label, path, class: ("current" if current))
  end
end
