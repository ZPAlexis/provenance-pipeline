# One question for the operator about one company or role: what an agent saw
# that needs a person's judgment (ReviewQueue). Open until the operator decides
# it or the evidence resolves; left items come back only on new evidence.
class ReviewItem < ApplicationRecord
  belongs_to :company
  # The company or role asked about; nil once a withdrawn suggestion is gone (its items close with it).
  belongs_to :subject, polymorphic: true, optional: true
  # No `dependent:` on purpose — see Posting#audit_events.
  has_many :audit_events, as: :target

  KINDS = %w[careers_page_candidate company_kind no_careers_page partial_list suspect_verdict unconfirmed_role].freeze
  STATUSES = %w[open done left].freeze

  validates :kind, inclusion: { in: KINDS }
  validates :status, inclusion: { in: STATUSES }
  validates :evidence, :evidence_key, :raised_by, presence: true

  scope :open, -> { where(status: "open") }
  scope :oldest_first, -> { order(:created_at) }
end
