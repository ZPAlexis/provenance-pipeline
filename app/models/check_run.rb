# A check the operator asked for from the pages, run in the background (CheckNowJob).
# The page polls it until it is done. Evidence and changes are recorded as for any
# check, under run_id; this row is the request and its outcome.
class CheckRun < ApplicationRecord
  belongs_to :company
  belongs_to :posting, optional: true

  KINDS = %w[role company].freeze
  STATUSES = %w[queued running done failed].freeze
  ACTIVE = %w[queued running].freeze
  # Longer than any check takes (a ten-page list read by the LLM, or a 2,000-role
  # Workday board, take minutes): a run still active after this was cut off.
  STALE_AFTER = 1.hour

  validates :kind, inclusion: { in: KINDS }
  validates :status, inclusion: { in: STATUSES }
  validates :requested_by, presence: true
  validates :posting, presence: true, if: -> { kind == "role" }

  scope :active, -> { where(status: ACTIVE) }
  scope :newest_first, -> { order(created_at: :desc) }

  # Marks runs that will never finish as cut off: active for over an hour, or, on
  # an in-process queue, left active by an earlier server process, whose queue
  # went with it. Otherwise a restart mid-check would block that role's next
  # check for an hour.
  def self.abandon_stale!(booted_at: Rails.configuration.x.booted_at)
    cutoff = [ STALE_AFTER.ago, (booted_at if in_process_queue?) ].compact.max
    active.where(updated_at: ...cutoff)
          .update_all(status: "failed", error: "Cut off: the server stopped before the check finished.",
                      finished_at: Time.current, updated_at: Time.current)
  end

  def self.in_process_queue? = CheckNowJob.queue_adapter.is_a?(ActiveJob::QueueAdapters::AsyncAdapter)

  # The check of a role or a company already under way, or a new one queued, with
  # what it could cost: one at a time per role and per company.
  def self.start_for!(record, requested_by: AuditEvent::OPERATOR)
    abandon_stale!
    role = record.is_a?(Posting)
    runs = role ? where(posting: record) : where(company: record, kind: "company")
    runs.active.first || create!(
      kind: role ? "role" : "company", company: role ? record.company : record, posting: (record if role),
      requested_by: requested_by, ceiling_usd: Verifier::CheckNow.ceiling(record)
    ).tap { |run| CheckNowJob.perform_later(run) }
  end

  def active? = ACTIVE.include?(status)

  def target_name
    kind == "role" ? "#{posting&.role_title || 'a withdrawn role'} at #{company.name}" : company.name
  end
end
