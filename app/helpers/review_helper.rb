module ReviewHelper
  KIND_LABELS = {
    "careers_page_candidate" => "Careers page to confirm", "company_kind" => "Kind of company",
    "no_careers_page" => "No careers page", "partial_list" => "Part of a list",
    "suspect_verdict" => "Suspect answer", "unconfirmed_role" => "Couldn't confirm"
  }.freeze

  # What to look at before deciding, per kind: the queue's guidance.
  GUIDANCE = {
    "careers_page_candidate" => "Open the page. Confirm it when it lists this company's own open roles, or links to all of them. " \
                                "Reject it when it is another company's, a job board, or shows no roles; set the right page if you know it.",
    "company_kind" => "An employer lists its own roles. A recruiter's own board lists its clients' roles, and those are its openings: " \
                      "it is watched. An aggregator lists other companies' postings: its page says nothing about them, so it is never watched.",
    "no_careers_page" => "Look on the company's own site for Careers, Jobs, or Work with us, and where its job ads link (often an ATS: " \
                         "Greenhouse, Lever, Workday, Oracle, Gupy). Blocked means its robots.txt keeps the verifier off that page; " \
                         "a board on an ATS may still be readable. Set the page you find, or leave it when it has none in public.",
    "partial_list" => "The page shows part of its roles: a first page, a search, a \"load more\" that stopped. Look for a page or an ATS " \
                      "board listing them all and set it, or leave it when there is none.",
    "suspect_verdict" => "Open the role's own page and its company's careers page, and record what you see. Undo the verdict when it " \
                         "came from a read that went wrong.",
    "unconfirmed_role" => "The site refused or failed the verifier. Open the role's page yourself and record what you see, or check it again later."
  }.freeze

  PROPOSALS = {
    "confirm" => "Confirm it", "find_again" => "Find its careers page again", "set_page" => "Set its careers page by hand",
    "hand_check" => "Look at its page and record what you see", "check_again" => "Check it again"
  }.freeze

  def review_kind_label(kind) = KIND_LABELS.fetch(kind, kind.humanize)

  def review_guidance(item) = GUIDANCE.fetch(item.kind, "")

  def review_proposal(item)
    return "Set its kind to #{item.proposal.delete_prefix('set_kind:')}" if item.proposal.to_s.start_with?("set_kind:")

    PROPOSALS.fetch(item.proposal.to_s, item.proposal.to_s.humanize)
  end

  # The question an item asks, in the operator's words.
  def review_question(item)
    company = item.company.name
    role = item.subject.is_a?(Posting) ? item.subject.role_title : "a withdrawn role"
    case item.kind
    when "careers_page_candidate" then "Is this #{company}'s own careers page?"
    when "company_kind" then "Is #{company} a #{item.evidence_key}?"
    when "no_careers_page" then "Where does #{company} list its open roles?"
    when "partial_list" then "Is there a page listing all of #{company}'s roles?"
    else "Is #{role} at #{company} still listed?"
    end
  end

  # Who an item is about, each linked to its page: the company, and the role when the question is about one.
  def review_subject_links(item)
    company = link_to(item.company.name, company_path(item.company), class: "review-company")
    return company unless item.subject.is_a?(Posting)

    safe_join([ company, tag.span("/", class: "muted"), link_to(item.subject.role_title, role_path(item.subject)) ], " ")
  end

  def review_open_count = ReviewItem.open.count
end
