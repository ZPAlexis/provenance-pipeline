# A check the operator asked for from the pages, run in the background (CheckNowJob):
# one role, one company, or everything (1.4). The page polls it until it is done.
# Evidence and changes are recorded as for any check, under run_id; this row is the
# request and its outcome.
class CheckRun < ApplicationRecord
  belongs_to :company, optional: true # none for everything
  belongs_to :posting, optional: true

  KINDS = %w[role company all].freeze
  STATUSES = %w[queued running done failed].freeze
  ACTIVE = %w[queued running].freeze
  # Longer than any check takes (a ten-page list read by the LLM, or a 2,000-role
  # Workday board, take minutes): a run still active after this was cut off.
  STALE_AFTER = 1.hour
  # Everything takes longer: about 40 minutes for 133 companies (2026-10-05).
  ALL_STALE_AFTER = Authority::BATCH

  validates :kind, inclusion: { in: KINDS }
  validates :status, inclusion: { in: STATUSES }
  validates :requested_by, presence: true
  validates :posting, presence: true, if: -> { kind == "role" }
  validates :company, presence: true, unless: -> { kind == "all" }

  scope :active, -> { where(status: ACTIVE) }
  scope :newest_first, -> { order(created_at: :desc) }

  # Marks runs that will never finish as cut off: active for over an hour, or, on
  # an in-process queue, left active by an earlier server process, whose queue
  # went with it. Otherwise a restart mid-check would block that role's next
  # check for an hour.
  def self.abandon_stale!(booted_at: Rails.configuration.x.booted_at)
    boot = (booted_at if in_process_queue?)
    one = [ STALE_AFTER.ago, boot ].compact.max
    all = [ ALL_STALE_AFTER.ago, boot ].compact.max
    active.where.not(kind: "all").where(updated_at: ...one).or(active.where(kind: "all", updated_at: ...all))
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

  # Everything checked at once, or the run already under way: one at a time.
  def self.start_all!(requested_by: AuditEvent::OPERATOR)
    abandon_stale!
    where(kind: "all").active.first || create!(
      kind: "all", requested_by: requested_by, ceiling_usd: Verifier::CheckAll.plan.ceiling
    ).tap { |run| CheckNowJob.perform_later(run) }
  end

  def active? = ACTIVE.include?(status)

  # How many companies a check of everything has read so far, from its results file as the worker writes it.
  def progress
    return unless kind == "all" && run_id

    file = Rails.root.join("tmp/verifier", run_id, "results.jsonl")
    file.exist? ? file.each_line.count : 0
  end

  def target_name
    case kind
    when "role" then "#{posting&.role_title || 'a withdrawn role'} at #{company.name}"
    when "all" then "everything"
    else company.name
    end
  end
end
