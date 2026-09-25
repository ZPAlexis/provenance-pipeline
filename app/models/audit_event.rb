class AuditEvent < ApplicationRecord
  belongs_to :target, polymorphic: true, optional: true

  validates :actor, presence: true
  validates :action, presence: true

  before_validation :default_occurred_at, on: :create

  scope :by_actor, ->(actor) { where(actor: actor) }
  scope :by_agents, -> { where("actor LIKE ?", "agent:%") }
  scope :recent, ->(since = 24.hours.ago) { where(occurred_at: since..) }

  # Every write to the system records who made it, what changed, and why.
  def self.record!(actor:, action:, target: nil, changes_made: {}, model_version: nil, reasoning: nil)
    create!(
      actor: actor,
      action: action,
      target: target,
      changes_made: changes_made,
      model_version: model_version,
      reasoning: reasoning,
      occurred_at: Time.current
    )
  end

  private

  def default_occurred_at
    self.occurred_at ||= Time.current
  end
end
