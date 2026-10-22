# One version of the operator's resume (Stage 2b), pasted on the Profile page:
# what the drafter reads (Drafts). Personal data, held in this database
# only. Kept and removed through Resumes, which audits each version by its size
# and hash, never its text.
class Resume < ApplicationRecord
  belongs_to :search_profile

  validates :text, :content_hash, presence: true

  scope :newest_first, -> { order(created_at: :desc) }

  def self.digest(text) = "sha256:#{Digest::SHA256.hexdigest(text.to_s.gsub(/\s+/, ' ').strip)}"

  def words = text.split.size

  # Its non-blank lines, each stripped, numbered from 1 as the worker's draft numbers them (draft.resume_lines),
  # so a line cited by number means the same line in the app, the worker, and an MCP client.
  def numbered_lines
    text.split(/\r\n|[\n\r\v\f\u001c-\u001e\u0085  ]/).map { |line| line.gsub(/\A[[:space:]]+|[[:space:]]+\z/, "") }
        .reject(&:empty?).each.with_index(1).map { |line, number| [ number, line ] }
  end
end
