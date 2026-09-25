class Posting < ApplicationRecord
  belongs_to :company
  has_many :audit_events, as: :target, dependent: :nullify

  VERIFICATION_STATES = %w[pending verified_live not_found inaccessible].freeze
  WORK_MODES = %w[remote hybrid onsite unknown].freeze

  validates :role_title, presence: true
  validates :verification_state, inclusion: { in: VERIFICATION_STATES }
  validates :work_mode, inclusion: { in: WORK_MODES }, allow_nil: true
  validates :posting_url, uniqueness: true, allow_nil: true

  scope :pending, -> { where(verification_state: "pending") }
  scope :live, -> { where(verification_state: "verified_live") }
  scope :remote, -> { where(work_mode: "remote") }
  scope :from_slice, ->(slice) { where(source_slice: slice) }

  # A `not_found` verdict with zero roles visible on the page is almost
  # certainly a rendering or parsing failure rather than a real negative —
  # the agent reached the page but could not read it. Surfaced as a scope so
  # these are triaged rather than silently trusted.
  scope :suspect_negatives, -> {
    where(verification_state: "not_found").where(roles_listed_count: [ nil, 0 ])
  }

  scope :credible_negatives, -> {
    where(verification_state: "not_found").where("roles_listed_count > 0")
  }

  def suspect_negative?
    verification_state == "not_found" && roles_listed_count.to_i.zero?
  end
end
