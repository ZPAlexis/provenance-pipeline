module ReviewHelper
  PROPOSALS = {
    "confirm" => "Confirm it", "find_again" => "Find its careers page again", "set_page" => "Set its careers page by hand",
    "hand_check" => "Look at its page and record what you see", "check_again" => "Check it again",
    "review_page" => "Look at its page: is it still this company's list?"
  }.freeze

  # Labels, questions and what to check come from ReviewGuidance, shared with the review commands and MCP (2g).
  def review_kind_label(kind) = ReviewGuidance.label(kind)

  def review_guidance(item) = ReviewGuidance.guidance(item.kind)

  def review_question(item) = ReviewGuidance.question(item)

  def review_proposal(item)
    return "Set its kind to #{item.proposal.delete_prefix('set_kind:')}" if item.proposal.to_s.start_with?("set_kind:")

    PROPOSALS.fetch(item.proposal.to_s, item.proposal.to_s.humanize)
  end

  # Who an item is about, each linked to its page: the company, and the role when the question is about one.
  def review_subject_links(item)
    company = link_to(item.company.name, company_path(item.company), class: "review-company")
    return company unless item.subject.is_a?(Posting)

    safe_join([ company, tag.span("/", class: "muted"), link_to(item.subject.role_title, role_path(item.subject)) ], " ")
  end

  def review_open_count = ReviewItem.open.count
end
