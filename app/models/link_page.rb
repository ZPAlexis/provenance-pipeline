# One version of a page one of the operator's links showed (4d): the link's own page, a page it links to on the same
# site, or a GitHub repo's README. Read free, never by the LLM; a read finding the same text again only moves
# last_read_at, a changed text is a new row. Evidence of what the page said, written by the verifier.
class LinkPage < ApplicationRecord
  belongs_to :profile_link

  validates :url, :text, :content_hash, :read_via, :run_id, :first_read_at, :last_read_at, presence: true

  def words = text.split.size
end
