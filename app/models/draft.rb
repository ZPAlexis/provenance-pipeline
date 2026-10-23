# Writing for an application, for the operator to edit and approve: a cover letter or an outreach note
# (Stage 2c), written by the in-app drafter or by the operator's own Claude client through MCP (2d), or a
# resume tailored to the role (2d, through MCP). Nothing is ever sent: the operator copies it out. A
# polished version is a new draft that revises the one before. Written and changed through Drafts, which
# audits each by its size and hash, never its text.
class Draft < ApplicationRecord
  KINDS = %w[cover_letter outreach tailored_resume].freeze
  # What the in-app drafter writes; a tailored resume comes through MCP alone, for now.
  IN_APP = %w[cover_letter outreach].freeze
  STATUSES = %w[draft approved].freeze
  LABELS = { "cover_letter" => "Cover letter", "outreach" => "Outreach note", "tailored_resume" => "Tailored resume" }.freeze
  A_LABEL = { "cover_letter" => "a cover letter", "outreach" => "an outreach note", "tailored_resume" => "a tailored resume" }.freeze
  WRITERS = { "agent:drafter" => "the in-app drafter", "agent:assistant" => "your Claude client, through MCP" }.freeze

  belongs_to :application
  belongs_to :resume, optional: true # nil once the resume is deleted; resume_hash still names it
  belongs_to :role_description, optional: true
  belongs_to :llm_call, optional: true
  belongs_to :revises, class_name: "Draft", optional: true # the draft this one polishes
  belongs_to :contact, optional: true # the person an outreach note is addressed to (2e)
  has_many :revisions, class_name: "Draft", foreign_key: :revises_id, inverse_of: :revises, dependent: :nullify

  validates :kind, inclusion: { in: KINDS }
  validates :status, inclusion: { in: STATUSES }
  validates :written_by, inclusion: { in: WRITERS.keys }
  validates :language, :body, :written_body, :resume_hash, :description_hash, :run_id, presence: true
  validate :addressed_to_its_companys_contact

  scope :newest_first, -> { order(created_at: :desc) }

  def self.label(kind) = LABELS.fetch(kind)

  def label = self.class.label(kind)

  def approved? = status == "approved"

  def tailored_resume? = kind == "tailored_resume"

  # The text as it stands, against what was written.
  def edited? = body != written_body || subject != written_subject

  def words = body.split.size

  # Who wrote it, in words.
  def writer = WRITERS.fetch(written_by)

  # A hash of the text as it stands, subject included: what its audit events name in its place.
  def content_hash = Resume.digest([ subject, body ].compact.join("\n"))

  private

  # Only an outreach note is addressed to someone, and only to one of its application's company's contacts.
  def addressed_to_its_companys_contact
    return unless contact

    errors.add(:contact, "is for an outreach note alone") unless kind == "outreach"
    errors.add(:contact, "must be at the application's company") if application && contact.company_id != application.company_id
  end
end
