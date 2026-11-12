# What a piece of writing read of the operator's background (4c): the one part its kind may use, by its hash, and the
# lines it drew from it, kept with the points, suggestions or changes that cite them, each to be confirmed by the
# operator ("from your background, not on the resume").
module ReadsBackground
  extend ActiveSupport::Concern

  # The part of the background each kind of writing may read: background not on the resume for a resume review or a
  # tailored resume (drawn on, flagged); what they're looking for for a cover letter or an outreach note (motivation
  # only, never cited). An outreach note is "outreach" on a draft, "outreach_note" to a client.
  PARTS = { "resume_review" => "not_on_resume", "tailored_resume" => "not_on_resume", "cover_letter" => "looking_for",
            "outreach" => "looking_for", "outreach_note" => "looking_for" }.freeze
  # The kinds whose part is only for motivation: none of its lines is ever cited.
  MOTIVATION_ONLY = %w[cover_letter outreach outreach_note].freeze

  included do
    belongs_to :background, optional: true # nil once the background is deleted; background_hash still names what it read
  end

  # Whether the part it read changed since it was written: changed, emptied, or deleted.
  def background_stale_for(background) = background_hash.present? && background&.hash_of(background_part) != background_hash

  # Of `items`, those drawn from the background: they cite its lines.
  def from_background(items) = Array(items).select { |item| Array(item["background_lines"]).any? }
end
