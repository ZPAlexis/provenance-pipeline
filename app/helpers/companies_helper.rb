module CompaniesHelper
  # A company's domain as a link to its site, opened in a new tab (4a): checking a company is a click, not a copy.
  def domain_link(company)
    return tag.span("no domain", class: "muted") if company.domain.blank?

    link_to(company.domain, "https://#{company.domain}", target: "_blank", rel: "noopener noreferrer", title: "Open #{company.domain}")
  end

  # Its careers page, or where finding one stands: waiting for the operator to confirm, not found, or not tried.
  def careers_page_cell(company)
    return outside_link(company.careers_page_url) if company.careers_page_url.present? && company.resolution_status == "resolved"
    if company.resolution_status == "candidate"
      return safe_join([ tag.span("to confirm", class: "badge unsure"), " ", outside_link(company.resolution_candidate_url) ])
    end

    tag.span(company.resolution_status == "failed" ? "none found" : "not looked for yet", class: "muted")
  end

  # Its roles in a line (WatchList.roles_line): tracked and suggested, then its tracked roles by their answer at the
  # last check and how many are archived, what the "No role tracked" and "None still listed" filters go by.
  def roles_summary(company, counts)
    head, detail = WatchList.roles_line(company.id, counts)
    return tag.span("none", class: "muted") if head.empty? && detail.empty?

    safe_join([ head.presence, (tag.div(detail, class: "muted small") if detail.present?) ].compact)
  end

  # --- How well a company fits the company preferences (4b) -------------------------------------------------------

  # What each point of a review weighs, in the operator's words.
  REVIEW_ABOUT = { "wants" => "What you want", "avoids" => "What you avoid", "stage" => "Stage", "size" => "Size",
                   "business_model" => "Business model", "industries" => "Industries", "excluded" => "Words to avoid",
                   "places" => "Where you can work" }.freeze
  # A point's verdict: it meets the preference, it doesn't, or nothing was found.
  VERDICTS = { "match" => [ "met", "live" ], "miss" => [ "missed", "gone" ], "unknown" => [ "unknown", nil ] }.freeze
  # Whose board a proposal named, as the app's own read found it.
  BOARD_OWNERS = { "confirmed" => "the board names the company", "unconfirmed" => "nothing ties the board to the company yet",
                   "another company's" => "the board is another company's" }.freeze

  # A company's newest review in a table cell: its score as a badge, marked when the preferences or places changed since.
  def company_fit_cell(review, profile)
    return tag.span("—", class: "muted", title: "Not reviewed yet") unless review

    safe_join([ link_to(fit_badge(review.score), company_path(review.company_id, anchor: "review"), title: "Fit, out of 100: its review"),
                (tag.span(" stale", class: "muted small", title: "Your company preferences or places changed since") if review.stale?(profile)) ])
  end

  def verdict_badge(verdict)
    said, tone = VERDICTS.fetch(verdict, [ verdict, nil ])
    tag.span(said, class: [ "badge", tone ])
  end

  def review_about(about) = REVIEW_ABOUT.fetch(about, about.to_s.humanize)

  # The facts a review found that the pages filter on, in a line: "Series B · 201-500 people · B2B · Fintech · Latin America".
  def review_facts(review)
    [ SearchProfile::COMPANY_STAGES[review.stage], ("#{review.size} people" if review.size), SearchProfile::COMPANY_MODELS[review.business_model],
      review.industries.join(", ").presence, ("hires in #{review.regions.join(', ')}" if review.regions.any?) ].compact.join(" · ")
  end

  # Links named as a fact's or a point's sources, by their host.
  def source_links(urls)
    return "".html_safe if Array(urls).empty?

    safe_join([ " [", safe_join(Array(urls).map { |url| outside_link(url, host_only: true) }, ", "), "]" ])
  end

  # Where a proposal was found: the source, with the query or company it went by.
  def proposal_source(proposal)
    source = Verifier::Proposals::SOURCES.fetch(proposal["source"].to_s, "somewhere")
    proposal["query"].present? ? "#{source.upcase_first} (#{proposal['query']})" : source.upcase_first
  end

  # What the app's own free read of a proposal's board found when it was proposed: its roles, how many hold one of
  # the profile's titles, and whose board it is.
  def proposal_board(proposal)
    seen = proposal["seen"]
    return tag.span("No known board among its links: none read.", class: "muted") if seen.blank?
    return tag.span("Nothing read#{": #{seen['why'].to_s.delete_suffix('.')}" if seen['why']}.", class: "muted") unless seen["board"]

    fitting = ", #{seen['fitting']} holding one of your titles" if seen["fitting"]
    owner = BOARD_OWNERS[seen["owner"]]
    read_at = begin
      Time.zone.parse(seen["read_at"].to_s) # the worker's time, as it wrote it
    rescue ArgumentError
      nil
    end
    safe_join([ outside_link(seen["board"]), ": #{pluralize(seen['roles'].to_i, 'role')}#{fitting}#{"; #{owner}" if owner}",
                (safe_join([ ", read ", ago(read_at) ]) if read_at) ].compact)
  end
end
