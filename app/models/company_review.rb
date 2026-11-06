# How well a company fits the operator's company preferences (4b), as their own Claude client researched it: a score
# from 0 to 100 and why; the facts found, each with its sources, and the stage, size, business model, industries and
# the regions it operates and hires in as values the pages filter on; one line per preference (match: it meets it;
# miss: it doesn't; unknown: nothing found), with the evidence; concerns, open questions, and the sources checked.
# Every review is kept and the newest shown, stale once the preferences it was read against change. Advice for
# choosing companies: it claims nothing. Written through CompanyReviews, which audits it by its score, counts and
# digests, never its text: it is read against the operator's own preferences.
class CompanyReview < ApplicationRecord
  WRITERS = { "agent:assistant" => "your Claude client, through MCP" }.freeze
  VERDICTS = %w[match miss unknown].freeze
  # What a point weighs: one of the company preferences, or where it hires against the places the operator can work.
  ABOUT = %w[wants avoids stage size business_model industries excluded places].freeze
  # A company that does what the operator avoids is no fit, however much else it meets: never amber or green.
  AVOIDED = %w[avoids excluded].freeze
  AVOIDED_CAP = 49

  belongs_to :company

  validates :score, numericality: { only_integer: true, in: 0..100 }
  validates :why, :preferences_digest, presence: true
  validates :written_by, inclusion: { in: WRITERS.keys }
  validates :stage, inclusion: { in: SearchProfile::COMPANY_STAGES.keys }, allow_nil: true
  validates :size, inclusion: { in: SearchProfile::COMPANY_SIZES }, allow_nil: true
  validates :business_model, inclusion: { in: SearchProfile::COMPANY_MODELS.keys }, allow_nil: true
  validate :points_said, :capped

  scope :newest_first, -> { order(created_at: :desc) }

  def writer = WRITERS.fetch(written_by)

  # How many preferences it meets, misses, and found nothing on.
  def tally = VERDICTS.to_h { |verdict| [ verdict, points.count { |point| point["verdict"] == verdict } ] }

  # Read against other preferences, or the places, than the profile has now.
  def stale?(profile = SearchProfile.current) = profile.nil? || profile.company_preferences_digest != preferences_digest

  # It knows less than it doesn't: more preferences unknown than met and missed together.
  def thin?
    counts = tally
    counts["unknown"] > counts["match"] + counts["miss"]
  end

  # Every source it names: checked, behind a fact, or behind a point.
  def all_sources = [ *sources, *facts.flat_map { |fact| fact["sources"] }, *points.flat_map { |point| point["sources"] } ].compact.uniq

  private

  def points_said
    points.each_with_index do |point, index|
      if !point.is_a?(Hash) || !ABOUT.include?(point["about"]) || point["preference"].blank?
        errors.add(:points, "#{index + 1} must say what it weighs (#{ABOUT.join(', ')}) and the preference")
      elsif !VERDICTS.include?(point["verdict"])
        errors.add(:points, "#{index + 1}'s verdict can only be #{VERDICTS.to_sentence(last_word_connector: ', or ')}")
      end
    end
  end

  def capped
    missed = points.any? { |point| point.is_a?(Hash) && AVOIDED.include?(point["about"]) && point["verdict"] == "miss" }
    return unless missed && score.to_i > AVOIDED_CAP

    errors.add(:score, "can be at most #{AVOIDED_CAP}: it does something the operator avoids")
  end
end
