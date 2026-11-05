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
end
