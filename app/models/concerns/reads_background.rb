# What a piece of writing read of the operator's background (4c): the one part its kind may use, by its hash, and the
# lines it drew from it, kept with the points, suggestions or changes that cite them, each to be confirmed by the
# operator ("from your background, not on the resume").
module ReadsBackground
  extend ActiveSupport::Concern

  # The part of the background each kind of writing may read.
  PARTS = { "resume_review" => "not_on_resume", "tailored_resume" => "not_on_resume" }.freeze

  included do
    belongs_to :background, optional: true # nil once the background is deleted; background_hash still names what it read
  end

  # Whether the part it read changed since it was written: changed, emptied, or deleted.
  def background_stale_for(background) = background_hash.present? && background&.hash_of(background_part) != background_hash

  # Of `items`, those drawn from the background: they cite its lines.
  def from_background(items) = Array(items).select { |item| Array(item["background_lines"]).any? }
end
