# One Claude API call, with what produced it and what it cost. Rows outlive the
# run directory that made them, so cost per page, per run, or per model over
# time is a query, not an archaeology dig.
class LlmCall < ApplicationRecord
  # The page the call read; none for a call that read no page (proposing titles for a profile).
  belongs_to :page_check, optional: true

  PURPOSES = %w[extract resolve match relate].freeze

  validates :run_id, :model, :prompt_version, :called_at, presence: true
  validates :purpose, inclusion: { in: PURPOSES }
  validates :input_tokens, :output_tokens, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :cost_usd, numericality: { greater_than_or_equal_to: 0 }
end
