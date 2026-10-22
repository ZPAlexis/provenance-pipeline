# An application for one role on record (Stage 2a): where it stands in the
# operator's pipeline, and what happened along the way. Only the operator starts
# one or moves it between stages: no agent scope allows writing one (Authority).
# Every change is audited, so the history of its stages is its audit events.
class Application < ApplicationRecord
  OPEN = %w[interested applied screening interviewing offer].freeze
  CLOSED = %w[accepted rejected withdrawn no_response].freeze
  STAGES = (OPEN + CLOSED).freeze

  belongs_to :posting
  belongs_to :company
  has_many :activities, dependent: :destroy
  has_many :drafts, dependent: :destroy
  has_many :resume_reviews, dependent: :destroy
  # No `dependent:` on purpose — see Posting#audit_events.
  has_many :audit_events, as: :target

  validates :stage, inclusion: { in: STAGES }
  validates :stage_changed_on, presence: true
  validates :posting_id, uniqueness: { message: "already has an application" }
  validate :company_is_the_roles

  scope :open, -> { where(stage: OPEN) }
  scope :closed, -> { where(stage: CLOSED) }

  def self.stage_label(stage) = stage.to_s.humanize

  def open? = OPEN.include?(stage)

  def days_in_stage(today = Date.current) = (today - stage_changed_on).to_i

  private

  def company_is_the_roles
    errors.add(:company, "must be the role's own") if posting && company_id != posting.company_id
  end
end
