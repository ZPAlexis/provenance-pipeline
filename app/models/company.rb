class Company < ApplicationRecord
  has_many :postings, dependent: :destroy
  # No `dependent:` on purpose — see Posting#audit_events.
  has_many :audit_events, as: :target

  ATS_TYPES = %w[greenhouse lever ashby workable own_site other unknown].freeze

  validates :name, presence: true
  validates :domain, uniqueness: true, allow_nil: true
  validates :ats_type, inclusion: { in: ATS_TYPES }, allow_nil: true

  scope :with_careers_page, -> { where.not(careers_page_url: nil) }
  scope :needing_careers_page, -> { where(careers_page_url: nil) }

  # Domain is the dedup key; fall back to a normalized name only when absent.
  #
  # Returns an unsaved record when nothing matches, so the caller can set every
  # attribute and save once — one write, one audit event — and can tell a create
  # from a match by `new_record?` without a second lookup.
  def self.find_or_initialize_for(name:, domain: nil)
    name = name.to_s.strip
    domain = domain.to_s.strip.downcase.presence

    if domain
      find_or_initialize_by(domain: domain) { |c| c.name = name }
    else
      find_or_initialize_by(name: name)
    end
  end
end
