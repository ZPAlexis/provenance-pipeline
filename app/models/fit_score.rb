# How well a role fits the resume (Stage 2f): a score from 0 to 100 with the level the role asks, the strongest
# matches with the resume lines behind them, the gaps, and why. Weighed from the role's own description by the fit
# scorer (Haiku 4.5, the operator's choice); kept with the resume and description versions it read, so a newer
# version of either makes it stale. Advice for ranking roles: it claims nothing. Written through FitScores, which
# audits each by its score, counts and hashes, never its text.
#
# Read two ways since 4c: `score` is the ATS fit, the resume alone as a recruiter's screening system reads it, shown in
# the tables; beside it, when the operator's background was read too, the Background fit: its score and why, the gaps of
# the ATS reading the background covers (each with its background lines and where to address it), and how the role sits
# with the role preferences. Each reading goes stale on its own: the Background fit also when the background changes.
class FitScore < ApplicationRecord
  WRITERS = { "agent:fit_scorer" => "the fit scorer", "agent:assistant" => "your Claude client, through MCP" }.freeze
  # Where a gap the background covers is to be addressed.
  ADDRESS_IN = { "resume" => "the resume", "cover_letter" => "the cover letter", "both" => "the resume and the cover letter" }.freeze
  PREFERENCE_VERDICTS = %w[match miss].freeze

  belongs_to :posting
  belongs_to :resume, optional: true # nil once the resume is deleted; resume_hash still names it
  belongs_to :role_description, optional: true
  belongs_to :llm_call, optional: true
  belongs_to :background, optional: true # nil once the background is deleted; background_hash still names it

  validates :score, numericality: { only_integer: true, in: 0..100 }
  validates :background_score, numericality: { only_integer: true, in: 0..100 }, allow_nil: true
  validates :written_by, inclusion: { in: WRITERS.keys }
  validates :why, :resume_hash, :description_hash, presence: true
  validates :background_why, :background_hash, presence: true, if: :background_reading?

  scope :newest_first, -> { order(created_at: :desc) }

  def writer = WRITERS.fetch(written_by)

  # What has changed since it was weighed, in words: the resume, the role's description, or nothing (empty).
  def stale_for(resume, description)
    [ ("the resume" if resume && resume.content_hash != resume_hash),
      ("the role's description" if description && description.content_hash != description_hash) ].compact
  end

  # Whether it was read with the background too.
  def background_reading? = background_score.present?

  # Whether its Background fit no longer reads the background as it is: changed since, or deleted.
  def background_stale_for(background) = background_reading? && background&.content_hash != background_hash

  # How the role sat with the role preferences: how many it met and missed.
  def preference_tally = PREFERENCE_VERDICTS.to_h { |verdict| [ verdict, preferences.count { |point| point["verdict"] == verdict } ] }
end
