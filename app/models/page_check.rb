# One observation of a company's page by the verifier. Evidence, not a change:
# rows here are the provenance for what a check saw, so they are not themselves
# audited. What a check changes on a company or posting goes through
# AuditEvent.record_write! as usual.
class PageCheck < ApplicationRecord
  belongs_to :company
  # The earlier read whose listings this check reused, its page's role links unchanged.
  belongs_to :reused_from, class_name: "PageCheck", optional: true
  has_many :llm_calls, dependent: :destroy

  PURPOSES = %w[resolution verification].freeze
  # How a page's listings were read by the LLM, or carried over from such a read: what a reuse can start from.
  PAGE_READS = %w[render+llm reused].freeze
  OUTCOMES = %w[ok blocked inaccessible error].freeze
  STEPS = %w[imported path_probe homepage homepage_link page_link ats_guess llm_link].freeze

  validates :run_id, :url, :checked_at, presence: true
  validates :purpose, inclusion: { in: PURPOSES }
  validates :outcome, inclusion: { in: OUTCOMES }
  validates :step, inclusion: { in: STEPS }, allow_nil: true
  validates :listing_count, numericality: { only_integer: true, greater_than_or_equal_to: 0 }, allow_nil: true

  scope :yielding, -> { where(outcome: "ok").where("listing_count > 0") }
end
