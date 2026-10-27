# A recommended decision on an open review item (Stage 2g), from the operator's own Claude client through MCP, as
# agent:assistant under review:recommend: one of the item's own actions, with the page or kind it needs, a
# confidence, what was checked, and why. Kept on the item (its `recommendation`) for the operator to accept in one
# click or not: it decides nothing, and makes none of the writes it recommends. One current recommendation an item: a
# newer one replaces it, and the audit keeps the earlier.
#
# What the operator then did is kept beside it (`taken`), so agreement is worked out per kind once the item closes:
# the measure any later autonomy would be judged on.
module ReviewRecommendations
  # The actions a recommendation may name, by kind. Never "still listed" or "no longer listed": those record what the
  # operator saw themselves, so accepting one would put another's reading on the record as theirs; "check again" runs a
  # real check instead.
  ACTIONS = {
    "careers_page_candidate" => %w[confirm reject set_page leave],
    "company_kind" => %w[set_kind leave],
    "no_careers_page" => %w[set_page find_again leave],
    "partial_list" => %w[set_page leave],
    "page_changed" => %w[set_page leave],
    "suspect_verdict" => %w[check_again undo leave],
    "unconfirmed_role" => %w[check_again leave]
  }.freeze
  CONFIDENCE = %w[high medium low].freeze
  OUTCOMES = %w[agreed differed resolved pending].freeze
  MAX_REASONING = 2_000
  MAX_CHECKED = 10

  module_function

  def actions(kind) = ACTIONS.fetch(kind, [])

  # Keeps `actor`'s recommendation on `item`, in place of any earlier one; audited, under the caller's credential.
  def save!(item, decision:, confidence:, reasoning:, url: nil, kind: nil, checked: [], reported_model: nil, actor: "agent:assistant")
    raise ArgumentError, "that item is decided already" unless item.status == "open"

    decision = decision.to_s.strip
    allowed = actions(item.kind)
    raise ArgumentError, "a recommendation on #{ReviewGuidance.label(item.kind).downcase} is one of: #{allowed.join(', ')}" unless allowed.include?(decision)
    raise ArgumentError, "confidence is one of: #{CONFIDENCE.join(', ')}" unless CONFIDENCE.include?(confidence.to_s)

    reasoning = reasoning.to_s.strip
    raise ArgumentError, "say why, in a few sentences: what you checked and what you saw" if reasoning.empty? || reasoning.size > MAX_REASONING

    url = url.to_s.strip.presence
    raise ArgumentError, "setting a page needs its address, as https://..." if decision == "set_page" && !Verifier::ResultContract.web_url?(url)

    kind = kind.to_s.strip.presence
    raise ArgumentError, "setting a kind needs one of: #{Company::KINDS.join(', ')}" if decision == "set_kind" && !Company::KINDS.include?(kind)

    recommendation = {
      "decision" => decision, "url" => (url if decision == "set_page"), "kind" => (kind if decision == "set_kind"),
      "confidence" => confidence.to_s, "reasoning" => reasoning,
      "checked" => Array(checked).map { |said| said.to_s.strip.truncate(300) }.reject(&:empty?).first(MAX_CHECKED),
      "by" => actor, "model" => WrittenFrom.reported(reported_model), "at" => Time.current.utc.iso8601
    }.compact
    item.update!(recommendation: recommendation)
    AuditEvent.record_write!(item, actor: actor, reasoning: "Recommended: #{said(recommendation).downcase_first} (#{confidence} confidence).")
    item
  end

  # What the operator did on an item carrying a recommendation, as kept beside it: the action, and the page or kind.
  def taken(item, decision, url: nil, kind: nil)
    return unless item.recommendation.present?

    item.recommendation.merge("taken" => { "decision" => decision, "url" => (url.to_s.strip if decision == "set_page"),
                                           "kind" => (kind.to_s if decision == "set_kind"), "at" => Time.current.utc.iso8601 }.compact)
  end

  # How a recommended item came out: pending while open; resolved when the record settled it before the operator acted;
  # otherwise agreed or differed, by what the operator did. Nil for an item that never carried one.
  def outcome(item)
    recommendation = item.recommendation.presence or return
    return "pending" if item.status == "open"

    taken = recommendation["taken"] or return "resolved"
    same?(recommendation, taken) ? "agreed" : "differed"
  end

  # Agreement per kind over every item that carried a recommendation: { kind => { outcome => count } }.
  def agreement(items = ReviewItem.where.not(recommendation: {}))
    items.to_a.group_by(&:kind).transform_values { |list| list.map { |item| outcome(item) }.tally }
  end

  def same?(recommendation, taken)
    return false unless recommendation["decision"] == taken["decision"]

    case taken["decision"]
    when "set_page" then same_page?(recommendation["url"], taken["url"])
    when "set_kind" then recommendation["kind"] == taken["kind"]
    else true
    end
  end

  # Two addresses for the same page: the scheme, a leading www. and a trailing slash aside.
  def same_page?(one, other)
    normal = ->(url) { url.to_s.strip.downcase.sub(%r{\Ahttps?://}, "").delete_prefix("www.").chomp("/") }
    normal.call(one) == normal.call(other)
  end

  # A recommendation's action, as a sentence a person would say.
  def said(recommendation)
    case recommendation["decision"]
    when "confirm" then "Confirm the page found"
    when "reject" then "Reject the page found"
    when "set_page" then "Set the page to #{recommendation['url']}"
    when "set_kind" then "Set its kind to #{recommendation['kind']}"
    when "find_again" then "Find its careers page again"
    when "check_again" then "Check it again"
    when "undo" then "Undo the verdict"
    else "Leave it as is"
    end
  end
end
