# A cover letter or an outreach note for an application (Stage 2c): written by
# the drafter from what is on record, then the operator's to edit and approve.
# Nothing is ever sent: the operator copies it out. Written and changed through
# Drafts, which audits each by its size and hash, never its text.
class Draft < ApplicationRecord
  KINDS = %w[cover_letter outreach].freeze
  STATUSES = %w[draft approved].freeze
  LABELS = { "cover_letter" => "Cover letter", "outreach" => "Outreach note" }.freeze

  belongs_to :application
  belongs_to :resume, optional: true # nil once the resume is deleted; resume_hash still names it
  belongs_to :role_description, optional: true
  belongs_to :llm_call, optional: true

  validates :kind, inclusion: { in: KINDS }
  validates :status, inclusion: { in: STATUSES }
  validates :language, :body, :written_body, :resume_hash, :description_hash, :run_id, presence: true

  scope :newest_first, -> { order(created_at: :desc) }

  def self.label(kind) = LABELS.fetch(kind)

  def label = self.class.label(kind)

  def approved? = status == "approved"

  # The text as it stands, against what the drafter wrote.
  def edited? = body != written_body || subject != written_subject

  def words = body.split.size

  # A hash of the text as it stands, subject included: what its audit events name in its place.
  def content_hash = Resume.digest([ subject, body ].compact.join("\n"))
end
