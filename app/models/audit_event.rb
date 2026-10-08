class AuditEvent < ApplicationRecord
  belongs_to :target, polymorphic: true, optional: true

  validates :actor, presence: true
  validates :action, presence: true

  before_validation :default_occurred_at, on: :create

  scope :by_actor, ->(actor) { where(actor: actor) }
  scope :by_agents, -> { where("actor LIKE ?", "agent:%") }
  scope :recent, ->(since = 24.hours.ago) { where(occurred_at: since..) }

  # The target reference already carries the id, and occurred_at the time.
  UNTRACKED_ATTRIBUTES = %w[id created_at updated_at].freeze

  # The one human operator, until 1.3 gives every actor a credential.
  OPERATOR = "human:operator".freeze

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

  # Records the save just made to `record` as a create or an update.
  #
  # changes_made holds { attribute => [before, after] } for everything the save
  # set, so creates and updates share one shape and one attribute's history is
  # a single query. A create snapshots every attribute it set, column defaults
  # included. JSONB hashes are diffed key by key: an overwrite keeps the value
  # it replaced, and no event carries a whole blob twice.
  #
  # Returns nil when the save changed nothing — no write, no event.
  def self.record_write!(record, actor:, reasoning: nil, model_version: nil)
    created = record.previously_new_record?
    changes = diff(created ? record.attributes.transform_values { |value| [ nil, value ] } : record.saved_changes)
    return if changes.empty?

    record!(
      actor: actor,
      action: created ? "create" : "update",
      target: record,
      changes_made: changes,
      model_version: model_version,
      reasoning: reasoning
    )
  end

  # Records `record` as it is about to be deleted: every attribute it held, as
  # [value, nil], so its whole history stays readable once the row is gone.
  def self.record_destroy!(record, actor:, reasoning: nil, model_version: nil)
    record!(
      actor: actor,
      action: "destroy",
      target: record,
      changes_made: diff(record.attributes.transform_values { |value| [ value, nil ] }),
      model_version: model_version,
      reasoning: reasoning
    )
  end

  def self.diff(changes)
    changes.except(*UNTRACKED_ATTRIBUTES).each_with_object({}) do |(attribute, (before, after)), acc|
      next if before == after

      change = before.is_a?(Hash) || after.is_a?(Hash) ? diff_hash(before || {}, after || {}) : [ before, after ]
      acc[attribute] = change unless change.empty?
    end
  end

  def self.diff_hash(before, after)
    (before.keys | after.keys).each_with_object({}) do |key, acc|
      acc[key] = [ before[key], after[key] ] unless before[key] == after[key]
    end
  end

  private_class_method :diff, :diff_hash

  private

  def default_occurred_at
    self.occurred_at ||= Time.current
  end
end
