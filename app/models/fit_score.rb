# How well a role fits the resume (Stage 2f): a score from 0 to 100 with the level the role asks, the strongest
# matches with the resume lines behind them, the gaps, and why. Weighed from the role's own description by the fit
# scorer (Haiku 4.5, the operator's choice); kept with the resume and description versions it read, so a newer
# version of either makes it stale. Advice for ranking roles: it claims nothing. Written through FitScores, which
# audits each by its score, counts and hashes, never its text.
class FitScore < ApplicationRecord
  WRITERS = { "agent:fit_scorer" => "the fit scorer", "agent:assistant" => "your Claude client, through MCP" }.freeze

  belongs_to :posting
  belongs_to :resume, optional: true # nil once the resume is deleted; resume_hash still names it
  belongs_to :role_description, optional: true
  belongs_to :llm_call, optional: true

  validates :score, numericality: { only_integer: true, in: 0..100 }
  validates :written_by, inclusion: { in: WRITERS.keys }
  validates :why, :resume_hash, :description_hash, presence: true

  scope :newest_first, -> { order(created_at: :desc) }

  def writer = WRITERS.fetch(written_by)

  # What has changed since it was weighed, in words: the resume, the role's description, or nothing (empty).
  def stale_for(resume, description)
    [ ("the resume" if resume && resume.content_hash != resume_hash),
      ("the role's description" if description && description.content_hash != description_hash) ].compact
  end
end
