# One version of a role's description, as its own page stated it (Stage 2b):
# read through its board's job API, or its page rendered, never by the LLM. A
# read that finds the same text moves last_read_at; a changed text is a new row.
class RoleDescription < ApplicationRecord
  belongs_to :posting

  validates :text, :content_hash, :read_via, :url, :run_id, :first_read_at, :last_read_at, presence: true

  scope :newest_first, -> { order(first_read_at: :desc, created_at: :desc) }

  def words = text.split.size

  def read_through
    read_via.start_with?("ats_api:") ? "#{read_via.delete_prefix('ats_api:').capitalize}'s job API" : "its page, rendered"
  end
end
