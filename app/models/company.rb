class Company < ApplicationRecord
  has_many :postings, dependent: :destroy
  has_many :audit_events, as: :target, dependent: :nullify

  ATS_TYPES = %w[greenhouse lever ashby workable own_site other unknown].freeze

  validates :name, presence: true
  validates :domain, uniqueness: true, allow_nil: true
  validates :ats_type, inclusion: { in: ATS_TYPES }, allow_nil: true

  scope :with_careers_page, -> { where.not(careers_page_url: nil) }
  scope :needing_careers_page, -> { where(careers_page_url: nil) }

  # Domain is the dedup key; fall back to a normalized name only when absent.
  def self.find_or_create_for!(name:, domain: nil)
    domain = domain.to_s.strip.downcase.presence

    if domain
      find_or_create_by!(domain: domain) { |c| c.name = name }
    else
      find_or_create_by!(name: name.to_s.strip)
    end
  end
end
