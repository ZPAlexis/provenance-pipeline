# How well a company fits the operator's company preferences (4b): reviewed only when the operator asks, by their own
# Claude client, which researches the company on the open web and saves the review back as agent:assistant under a
# credential holding company_reviews:write, read against the preferences version it saw. Every review is kept; the
# newest is shown, stale once the preferences or the places change. Audited by its score, counts and digests, never
# its text. A review never weighs into a role's fit: company fit and role fit are two scores.
module CompanyReviews
  ACTOR = "agent:assistant".freeze
  WORDS = 20

  module_function

  # Saves a review the client wrote, for `company` (tracked or proposed, never archived). Returns the review and what
  # was saved, in words.
  def save!(company, score:, why:, preferences_version:, stage: nil, size: nil, business_model: nil, industries: [], regions: [],
            facts: [], points: [], concerns: [], questions: [], sources: [], reported_model: nil)
    Authority.require_agent!(ACTOR)
    profile = SearchProfile.current
    raise ArgumentError, "the profile has no company preferences yet: the operator sets them first" unless profile&.company_preferences?
    unless preferences_version.to_s == profile.company_preferences_version
      raise ArgumentError, "the company preferences changed since you read them: read them again, and weigh it against them"
    end
    raise ArgumentError, "#{company.name} is archived: it isn't reviewed" if company.dismissed?
    raise ArgumentError, "a score is a whole number from 0 to 100" unless score.is_a?(Integer) && score.between?(0, 100)

    review = company.company_reviews.new(
      score: score, why: why.to_s.strip, stage: stage.presence, size: size.presence, business_model: business_model.presence,
      industries: words(industries), regions: words(regions), facts: facts(facts), points: points(points),
      concerns: texts(concerns), questions: texts(questions), sources: links(sources),
      preferences_digest: profile.company_preferences_digest, written_by: ACTOR, reported_model: reported_model.to_s.strip.presence
    )
    raise ArgumentError, "name the sources checked: a review rests on them" if review.all_sources.empty?

    ApplicationRecord.transaction do
      review.save!
      AuditEvent.record!(actor: ACTOR, action: "create", target: review, reasoning: "Reviewed through MCP: #{said(review)}.",
                         changes_made: audited(review).transform_values { |value| [ nil, value ] })
    end
    [ review, "#{said(review)}." ]
  end

  # The newest review of a company, or nil.
  def newest(company) = company.company_reviews.newest_first.first

  # The companies due a review, of those given (tracked and proposed, by default): none yet against the preferences
  # and places as they are now.
  def due(companies = Company.where(tracking: %w[tracked suggested]), profile: SearchProfile.current)
    return companies.none unless profile&.company_preferences?

    companies.where.not(id: CompanyReview.where(preferences_digest: profile.company_preferences_digest).select(:company_id))
  end

  # A review in a line: its score and how it weighed the preferences.
  def said(review)
    counts = review.tally
    "#{review.score}, #{counts['match']} met, #{counts['miss']} missed, #{counts['unknown']} unknown" \
      "#{', knowing less than it doesn\'t' if review.thin?}"
  end

  # What its audit events say of it: its score, counts and digests, never its text.
  def audited(review)
    { "score" => review.score, "points" => review.tally, "facts" => review.facts.size, "sources" => review.all_sources.size,
      "concerns" => review.concerns.size, "questions" => review.questions.size,
      "preferences_digest" => review.preferences_digest, "written_by" => review.written_by }
  end

  def words(list) = Array(list).map { |word| word.to_s.squish }.compact_blank.uniq(&:downcase).first(WORDS)

  def texts(list) = Array(list).map { |text| text.to_s.strip }.compact_blank

  def links(list)
    Array(list).map(&:to_s).map(&:strip).compact_blank.uniq.each do |url|
      raise ArgumentError, "#{url} is not a web address: a source is a link" unless Verifier::ResultContract.web_url?(url)
    end
  end

  def facts(list)
    Array(list).map(&:to_h).filter_map do |fact|
      fact = fact.transform_keys(&:to_s)
      next if fact["said"].to_s.strip.empty?

      { "about" => fact["about"].to_s.squish.presence || "other", "said" => fact["said"].to_s.strip, "sources" => links(fact["sources"]) }
    end
  end

  def points(list)
    Array(list).map(&:to_h).map do |point|
      point = point.transform_keys(&:to_s)
      { "about" => point["about"].to_s.strip, "preference" => point["preference"].to_s.strip, "verdict" => point["verdict"].to_s.strip,
        "evidence" => point["evidence"].to_s.strip.presence, "sources" => links(point["sources"]) }.compact
    end
  end

  private_class_method :audited, :words, :texts, :links, :facts, :points
end
