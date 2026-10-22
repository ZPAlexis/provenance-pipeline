# A review of the resume against an application's role (Stage 2d): strengths with the resume lines behind
# them, gaps, suggestions, and a note. Advice for the operator: it writes nothing to send and claims nothing.
# Written by the operator's own Claude client through MCP (and, from 2d step 4, in the app); kept with the
# resume and description versions it read. Saved and deleted through ResumeReviews, which audits each by its
# counts and hashes, never its text.
class ResumeReview < ApplicationRecord
  WRITERS = Draft::WRITERS

  belongs_to :application
  belongs_to :resume, optional: true # nil once the resume is deleted; resume_hash still names it
  belongs_to :role_description, optional: true
  belongs_to :llm_call, optional: true

  validates :written_by, inclusion: { in: WRITERS.keys }
  validates :language, :resume_hash, :description_hash, presence: true

  scope :newest_first, -> { order(created_at: :desc) }

  def writer = WRITERS.fetch(written_by)
end
