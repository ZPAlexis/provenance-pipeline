# A careers page rendered for the operator's own AI assistant to read (4f): a page a free check left unread, opened by
# the worker and never read by the AI here. Its text (cut where the extractor's is) and its links, numbered in the
# page's order as the extractor numbers them, are kept so what the assistant saves of the page can be checked against
# the page itself. Evidence, written by the verifier under its own credential.
class PageRender < ApplicationRecord
  # What one answer of read_careers_page holds at most: about 8,000 tokens, which a chat can take a few of.
  PART_CHARS = 30_000

  belongs_to :company
  belongs_to :page_check, optional: true

  validates :run_id, :url, :content_hash, :rendered_at, presence: true
  validates :text, exclusion: { in: [ nil ], message: "must be given, if empty" }
  validate :links_are_pairs

  scope :newest_first, -> { order(rendered_at: :desc) }

  # The links as the reader sees them: "[n] link text -> address", numbered from 1 in the page's order.
  def numbered_links = links.each_with_index.map { |(label, href), index| "[#{index + 1}] #{label.presence || '(no text)'} -> #{href}" }

  # The address behind link number `number` (1-based), or nil for one the page doesn't have.
  def link_url(number) = (links[number - 1]&.last if number.is_a?(Integer) && number.between?(1, links.size))

  # The page in parts a chat can hold, each a list of [kind, body] segments: its text first, then its links, each cut
  # at a line where it can be, and as few parts as they fit in (a short page is one part, its text and its links).
  def parts
    @parts ||= (chunks(text, :text) + chunks(numbered_links.join("\n"), :links)).each_with_object([]) do |segment, packed|
      if packed.any? && packed.last.sum { |_, body| body.size } + segment.last.size <= PART_CHARS
        packed.last << segment
      else
        packed << [ segment ]
      end
    end
  end

  private

  def chunks(body, kind)
    return [] if body.blank?

    pieces = []
    rest = body
    while rest.size > PART_CHARS
      cut = rest.rindex("\n", PART_CHARS) || PART_CHARS
      cut = PART_CHARS if cut < PART_CHARS / 2
      pieces << rest[0...cut]
      rest = rest[cut..].delete_prefix("\n")
    end
    (pieces << rest).map { |piece| [ kind, piece ] }
  end

  def links_are_pairs
    return if links.is_a?(Array) && links.all? { |link| link.is_a?(Array) && link.size == 2 && link.all?(String) }

    errors.add(:links, "must be [link text, address] pairs")
  end
end
