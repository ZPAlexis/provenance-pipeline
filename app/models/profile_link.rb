# One of the operator's own links (4d): their website, their GitHub, or another portfolio, kept with the search profile.
# At most MAX; never LinkedIn, whose pages can't be read (what matters from it belongs in the background). The
# operator's alone to edit (no scope allows an agent to); the verifier only records what a read found. Read by the app,
# free and never by the LLM (ProfileLinks), its pages kept as versions (LinkPage).
class ProfileLink < ApplicationRecord
  MAX = 5
  OUTCOMES = %w[ok gone blocked inaccessible error].freeze
  LINKEDIN = /(\A|\.)linkedin\.com\z/i
  LINKEDIN_REFUSAL = "LinkedIn isn't read: its pages can't be fetched, and what matters from it belongs in \"Background not " \
                     "on the resume\"".freeze

  belongs_to :search_profile
  has_many :link_pages, dependent: nil # the key cascades

  validates :label, presence: true, length: { maximum: 60 }
  validates :url, presence: true, length: { maximum: 500 }, uniqueness: { scope: :search_profile_id, message: "is given twice" }
  validates :read_outcome, inclusion: { in: OUTCOMES }, allow_nil: true
  validate :readable_address

  scope :in_order, -> { order(:position, :created_at) }

  # The pages its newest read found: each page's version seen then.
  def pages = read_at ? link_pages.where(last_read_at: read_at).order(:created_at).to_a : []

  def host = URI.parse(url).host.to_s.downcase.delete_prefix("www.")

  private

  def readable_address
    uri = URI.parse(url.to_s.strip)
    return errors.add(:url, "must be a web address (http or https)") unless uri.is_a?(URI::HTTP) && uri.host.present?

    errors.add(:base, LINKEDIN_REFUSAL) if uri.host.match?(LINKEDIN)
  rescue URI::InvalidURIError
    errors.add(:url, "must be a web address (http or https)")
  end
end
