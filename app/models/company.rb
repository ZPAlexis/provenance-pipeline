class Company < ApplicationRecord
  has_many :postings, dependent: :destroy
  has_many :page_checks, dependent: :destroy
  # No `dependent:` on purpose — see Posting#audit_events.
  has_many :audit_events, as: :target

  ATS_TYPES = %w[greenhouse lever ashby workday workable own_site other unknown].freeze

  # --- Careers-page resolution: the contract ---------------------------------
  #
  # careers_page_url is a watch target, polled for months, so how it was found
  # and how sure we are is recorded beside it. nil status = never attempted.
  #
  # resolved   careers_page_url is set, with its method and confidence.
  #            high: found on the company's own domain, or a board its own
  #            page links to or embeds. medium: a guessed board the vendor's
  #            own record confirms. confirmed: a human confirmed a candidate, or
  #            set the page by hand (method "manual").
  # candidate  a low-confidence find (an unconfirmed guess, or a link the LLM
  #            picked), held in resolution_candidate_url until a human
  #            confirms or rejects it. Never written as the watched page.
  # failed     nothing usable found; resolution_failure says why. Retried on a
  #            slower schedule; failures here are about finding the page, and
  #            are tracked apart from verification failures on postings.
  #            "anonymised" is a posting whose employer is withheld: there is
  #            no company to find. "rejected" is a candidate a human turned down.
  RESOLUTION_STATUSES = %w[resolved candidate failed].freeze
  RESOLUTION_METHODS = %w[imported path_probe homepage_link page_link ats_guess llm_link manual].freeze
  RESOLUTION_CONFIDENCES = %w[high medium low confirmed].freeze
  RESOLUTION_FAILURES = %w[no_domain anonymised not_found blocked inaccessible rejected].freeze

  # What kind of company: a recruiter's own board of client roles is its careers
  # page; an aggregator's listings are other companies' own postings. The operator
  # sets kind; resolution only suggests one (kind_suggestion, with kind_evidence).
  KINDS = %w[employer recruiter aggregator].freeze
  KIND_SUGGESTIONS = %w[recruiter aggregator].freeze

  validates :name, presence: true
  validates :domain, uniqueness: true, allow_nil: true
  validates :ats_type, inclusion: { in: ATS_TYPES }, allow_nil: true
  validates :resolution_status, inclusion: { in: RESOLUTION_STATUSES }, allow_nil: true
  validates :resolution_method, inclusion: { in: RESOLUTION_METHODS }, allow_nil: true
  validates :resolution_confidence, inclusion: { in: RESOLUTION_CONFIDENCES }, allow_nil: true
  validates :resolution_failure, inclusion: { in: RESOLUTION_FAILURES }, allow_nil: true
  validates :kind, inclusion: { in: KINDS }, allow_nil: true
  validates :kind_suggestion, inclusion: { in: KIND_SUGGESTIONS }, allow_nil: true
  with_options if: -> { resolution_status == "resolved" } do
    validates :careers_page_url, :resolution_method, :resolution_confidence, presence: true
  end
  with_options if: -> { resolution_status == "candidate" } do
    validates :resolution_candidate_url, :resolution_method, :resolution_confidence, presence: true
  end
  validates :resolution_failure, presence: true, if: -> { resolution_status == "failed" }

  scope :with_careers_page, -> { where.not(careers_page_url: nil) }
  scope :needing_careers_page, -> { where(careers_page_url: nil) }
  scope :unresolved, -> { where(resolution_status: nil) }
  scope :resolution_candidates, -> { where(resolution_status: "candidate") }

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
