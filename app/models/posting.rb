class Posting < ApplicationRecord
  belongs_to :company
  # No `dependent:` on purpose. The audit trail outlives the records it
  # describes: when a record is deleted its events keep target_type and
  # target_id, so its whole history stays queryable by id and no audit event is
  # ever modified after it is written. `event.target` returns nil once the record
  # is gone. (`dependent: :nullify` would clear both columns.)
  has_many :audit_events, as: :target

  # --- Verification fields: the contract ------------------------------------
  #
  # A *check* is an observation at the employer's own careers page that
  # produced a verdict: verified_live, not_found, or inaccessible. An upstream
  # answer that maps to none of them is not a check: the posting stays pending,
  # with no date, and the raw answer is kept in enrichment["raw_verification"].
  #
  # verification_state  The last check's verdict, or "pending" (never nil)
  #                     while there is no usable one.
  # last_checked_at     When that verdict was observed. Present exactly when
  #                     the posting has a verdict (validated below), so nil
  #                     means one thing only: never checked.
  # roles_listed_count  Roles visible on the page at that check, matched or
  #                     not: the corroborating observable that separates a
  #                     credible negative from a parse failure. nil = unknown,
  #                     never a sentinel.
  # work_mode           As observed at that check. nil = not observed.
  #
  # Writers and precision. ClayImporter sets these once: when it creates a
  # posting from a research export, or when a research export first reaches a
  # posting it imported unchecked. Clay exports carry no per-row check date,
  # so the operator supplies it (VERIFIED_AT, required whenever an export has
  # verdicts); a bare date is stored at 12:00 UTC and is day precision, and
  # the posting's create event says where the date came from. From Stage 1.2
  # the verifier is the main writer and records the exact time it observed the
  # page (Verifier::Ingest). A verdict that changes is an audited update. A
  # check that confirms the verdict refreshes last_checked_at, the count, and
  # the work mode with no audit event: its page check is the provenance. A check
  # that could not decide (part of a list read, nothing matched) writes nothing
  # here. The operator's own checks (verifier:hand_check) are verdicts too,
  # audited as theirs.
  # --- Tracking: the operator's watch list ----------------------------------
  #
  # suggested  proposed by the agent (from a search profile, 1.5c); checked with
  #            its company, for free, but not watched.
  # tracked    chosen by the operator: watched, and checked on demand.
  # dismissed  declined by the operator for good: never checked or suggested again.
  # Only the operator tracks or dismisses (Verifier::Tracking).
  #
  # job_url is the role's own page at the employer, learned from the listing it
  # matched; posting_url is where it was found (often LinkedIn, never fetched).
  TRACKING = %w[suggested tracked dismissed].freeze

  VERIFICATION_STATES = %w[pending verified_live not_found inaccessible].freeze
  VERDICTS = (VERIFICATION_STATES - %w[pending]).freeze
  WORK_MODES = %w[remote hybrid onsite unknown].freeze

  validates :role_title, presence: true
  validates :verification_state, inclusion: { in: VERIFICATION_STATES }
  validates :tracking, inclusion: { in: TRACKING }
  validates :work_mode, inclusion: { in: WORK_MODES }, allow_nil: true
  validates :posting_url, uniqueness: true, allow_nil: true
  validates :last_checked_at, presence: true, if: :verdict?
  validates :last_checked_at, absence: true, unless: :verdict?

  # Roles seen on the careers page — nothing else. An unknown count is nil,
  # never a sentinel: a negative would escape both negative-verdict scopes and
  # silently disable the parse-failure check.
  validates :roles_listed_count, numericality: { only_integer: true, greater_than_or_equal_to: 0 }, allow_nil: true

  scope :pending, -> { where(verification_state: "pending") }
  scope :tracked, -> { where(tracking: "tracked") }
  scope :not_dismissed, -> { where.not(tracking: "dismissed") }
  scope :live, -> { where(verification_state: "verified_live") }
  scope :remote, -> { where(work_mode: "remote") }
  scope :from_slice, ->(slice) { where(source_slice: slice) }

  # A `not_found` verdict with zero roles visible on the page is almost
  # certainly a rendering or parsing failure rather than a real negative —
  # the agent reached the page but could not read it. Surfaced as a scope so
  # these are triaged rather than silently trusted.
  scope :suspect_negatives, -> {
    where(verification_state: "not_found").where(roles_listed_count: [ nil, 0 ])
  }

  scope :credible_negatives, -> {
    where(verification_state: "not_found").where("roles_listed_count > 0")
  }

  def verdict?
    VERDICTS.include?(verification_state)
  end

  def suspect_negative?
    verification_state == "not_found" && roles_listed_count.to_i.zero?
  end
end
