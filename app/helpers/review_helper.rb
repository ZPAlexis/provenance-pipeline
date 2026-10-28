module ReviewHelper
  PROPOSALS = {
    "confirm" => "Confirm it", "find_again" => "Find its careers page again", "set_page" => "Set its careers page by hand",
    "hand_check" => "Look at its page and record what you see", "check_again" => "Check it again",
    "review_page" => "Look at its page: is it still this company's list?"
  }.freeze

  # A recommendation's Accept, named by what it does (2g).
  ACCEPT_LABELS = {
    "confirm" => "Accept: confirm the page", "reject" => "Accept: reject the page", "set_page" => "Accept: set this page",
    "set_kind" => "Accept: set its kind", "find_again" => "Accept: find it again", "check_again" => "Accept: check it again",
    "undo" => "Accept: undo the verdict", "leave" => "Accept: leave it as is"
  }.freeze

  def accept_label(recommendation) = ACCEPT_LABELS.fetch(recommendation["decision"], "Accept")

  # What accepting a recommendation does to the record, in a sentence.
  def accept_effect(item, recommendation)
    company = item.company.name
    case recommendation["decision"]
    when "confirm" then "Watches the page found as #{company}'s careers page; its roles are read at its next check."
    when "reject" then "Drops the page found; set the right one by hand if you know it."
    when "set_page"
      "Watches this page as #{company}'s careers page#{" in place of #{item.company.careers_page_url}" if item.company.careers_page_url}; " \
        "its roles are read at its next check. A page the app may not read leaves its roles to your hand checks."
    when "set_kind" then "Marks #{company} as a #{recommendation['kind']}."
    when "find_again" then "Looks for #{company}'s careers page again, in the background; the item closes if it finds one."
    when "check_again" then "Checks the role again, in the background; the item closes if the check settles it."
    when "undo" then "Restores the verdict before this one, with the reasoning above as your note."
    else "Closes the item with the reasoning above as your note; nothing else changes. It comes back only if what was seen changes."
    end
  end

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
