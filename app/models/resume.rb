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

  # A short name for this version, from its hash: what a client that read it gives back when it saves what it wrote,
  # so the line numbers it cites are read against the lines it saw.
  def version = content_hash.delete_prefix("sha256:")[0, 12]

  # The lines `numbers` name, with their text, in the order given and once each; and how many name no line here.
  def cite(numbers)
    lines = numbered_lines.to_h
    named = Array(numbers).map { |number| Integer(number, exception: false) }
    cited = named.uniq.filter_map { |number| { "line" => number, "text" => lines[number] } if lines.key?(number) }
    [ cited, named.count { |number| !lines.key?(number) } ]
  end

  # Its non-blank lines, each stripped, numbered from 1 as the worker's draft numbers them (draft.resume_lines),
  # so a line cited by number means the same line in the app, the worker, and an MCP client.
  def numbered_lines
    text.split(/\r\n|[\n\r\v\f\u001c-\u001e\u0085  ]/).map { |line| line.gsub(/\A[[:space:]]+|[[:space:]]+\z/, "") }
        .reject(&:empty?).each.with_index(1).map { |line, number| [ number, line ] }
  end
end
