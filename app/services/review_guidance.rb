# What each kind of review item asks, and what to look at before deciding it (1.5e): one source, read by the Review
# page, the review commands, and (2g) the operator's own Claude client through MCP when it recommends a decision, as
# the writing rules are one source for writing.
module ReviewGuidance
  LABELS = {
    "careers_page_candidate" => "Careers page to confirm", "company_kind" => "Kind of company",
    "no_careers_page" => "No careers page", "partial_list" => "Part of a list", "page_changed" => "Page changed a lot",
    "suspect_verdict" => "Suspect answer", "unconfirmed_role" => "Couldn't confirm"
  }.freeze

  # What to look at before deciding, per kind.
  GUIDANCE = {
    "careers_page_candidate" => "Open the page. Confirm it when it lists this company's own open roles, or links to all of them. " \
                                "Reject it when it is another company's, a job board, or shows no roles; set the right page if you know it.",
    "company_kind" => "An employer lists its own roles. A recruiter's own board lists its clients' roles, and those are its openings: " \
                      "it is watched. An aggregator lists other companies' postings: its page says nothing about them, so it is never watched.",
    "no_careers_page" => "Look on the company's own site for Careers, Jobs, or Work with us, and where its job ads link (often an ATS: " \
                         "Greenhouse, Lever, Workday, Oracle, Gupy). Set the page you find, even one its robots.txt keeps the " \
                         "verifier off (blocked): the right page goes on record, and its roles then come back to you to check " \
                         "by hand; a board on an ATS the verifier may read is better when there is one. Leave it only when " \
                         "the company has no public list of roles.",
    "partial_list" => "The page shows part of its roles: a first page, a search, a \"load more\" that stopped. Look for a page or an ATS " \
                      "board listing them all and set it, or leave it when there is none.",
    "page_changed" => "Open the page and compare it with what the company's own site links to as its jobs. Still its list (a " \
                      "hiring wave, a reorganised board): say so. Another company's list, a job board, or a page that moved: " \
                      "set the right page, and its roles are read there from then on.",
    "suspect_verdict" => "Open the role's own page and its company's careers page, and record what you see. Undo the verdict when it " \
                         "came from a read that went wrong.",
    "unconfirmed_role" => "The site refused or failed the verifier. Open the role's page yourself and record what you see, or check it again later."
  }.freeze

  module_function

  def label(kind) = LABELS.fetch(kind, kind.to_s.humanize)

  def guidance(kind) = GUIDANCE.fetch(kind, "")

  # The question an item asks, in the operator's words.
  def question(item)
    company = item.company.name
    role = item.subject.is_a?(Posting) ? item.subject.role_title : "a withdrawn role"
    case item.kind
    when "careers_page_candidate" then "Is this #{company}'s own careers page?"
    when "company_kind" then "Is #{company} a #{item.evidence_key}?"
    when "no_careers_page" then "Where does #{company} list its open roles?"
    when "partial_list" then "Is there a page listing all of #{company}'s roles?"
    when "page_changed" then "Is #{item.company.careers_page_url} still #{company}'s list of roles?"
    else "Is #{role} at #{company} still listed?"
    end
  end
end
