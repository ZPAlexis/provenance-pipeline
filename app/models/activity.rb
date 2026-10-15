# Something that happened on an application (Stage 2a): an email, a call, an
# interview. Logged by the operator for now; `logged_by` names who wrote it, as
# its audit event does.
class Activity < ApplicationRecord
  KINDS = %w[applied email call interview assessment offer note other].freeze

  belongs_to :application
  # No `dependent:` on purpose — see Posting#audit_events.
  has_many :audit_events, as: :target

  validates :kind, inclusion: { in: KINDS }
  validates :occurred_on, :summary, :logged_by, presence: true

  scope :latest_first, -> { order(occurred_on: :desc, created_at: :desc) }
end
