# One version of the operator's resume (Stage 2b), pasted on the Profile page:
# what the drafting agent to come reads. Personal data, held in this database
# only. Kept and removed through Resumes, which audits each version by its size
# and hash, never its text.
class Resume < ApplicationRecord
  belongs_to :search_profile

  validates :text, :content_hash, presence: true

  scope :newest_first, -> { order(created_at: :desc) }

  def self.digest(text) = "sha256:#{Digest::SHA256.hexdigest(text.to_s.gsub(/\s+/, ' ').strip)}"

  def words = text.split.size
end
