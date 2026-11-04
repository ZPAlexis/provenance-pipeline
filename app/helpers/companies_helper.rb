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

  # Each answer a tracked role can have, as the Roles page says it, in a company's roles line.
  ANSWERS = { "verified_live" => "still listed", "not_found" => "gone", "pending" => "no answer yet", "inaccessible" => "couldn't confirm" }.freeze

  # Its roles in a line: tracked (and suggested), then its tracked roles by their answer at the last check, and how
  # many are archived: what the "No role tracked" and "None still listed" filters go by. `counts` is
  # { [company_id, tracking, answer] => n }.
  def roles_summary(company, counts)
    mine = counts.filter_map { |(id, tracking, answer), n| [ tracking, answer, n ] if id == company.id }
    total = ->(&keep) { mine.sum { |tracking, answer, n| keep.call(tracking, answer) ? n : 0 } }
    tracked = total.call { |tracking, _| tracking == "tracked" }
    suggested = total.call { |tracking, _| tracking == "suggested" }
    archived = total.call { |tracking, _| tracking == "dismissed" }
    head = [ ("#{tracked} tracked" if tracked.positive?), ("#{suggested} suggested" if suggested.positive?) ].compact.join(", ")
    answers = ANSWERS.filter_map do |answer, said|
      n = total.call { |tracking, its| tracking == "tracked" && its == answer }
      "#{n} #{said}" if n.positive?
    end
    detail = answers + [ ("#{archived} archived" if archived.positive?) ].compact
    return tag.span("none", class: "muted") if head.empty? && detail.empty?

    safe_join([ head.presence, (tag.div(detail.join(" · "), class: "muted small") if detail.any?) ].compact)
  end
end
