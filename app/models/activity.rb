# Something that happened on an application (Stage 2a): an email, a call, an
# interview, perhaps with one of its company's contacts (2e). Logged by the operator,
# or by the activity logger through MCP (2e); `logged_by` names who wrote it, as its
# audit event does.
class Activity < ApplicationRecord
  KINDS = %w[applied email call interview assessment offer note other].freeze

  belongs_to :application
  belongs_to :contact, optional: true
  # No `dependent:` on purpose — see Posting#audit_events.
  has_many :audit_events, as: :target

  validates :kind, inclusion: { in: KINDS }
  validates :occurred_on, :summary, :logged_by, presence: true
  validate :contact_at_the_applications_company

  scope :latest_first, -> { order(occurred_on: :desc, created_at: :desc) }

  private

  def contact_at_the_applications_company
    errors.add(:contact, "must be at the application's company") if contact && application && contact.company_id != application.company_id
  end
end
