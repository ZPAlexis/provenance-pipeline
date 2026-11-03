# A check the operator asked for from the pages, run in the background (CheckNowJob):
# one role, one company, everything (1.4), a role's description read (2b), a
# draft written for its application (2c), a resume review written for it (2d), or
# the fit of one role or many weighed against the resume (2f).
# The page polls it until it is done.
# Evidence and changes are recorded as for any check, under run_id; this row is the
# request and its outcome.
class CheckRun < ApplicationRecord
  belongs_to :company, optional: true # none for everything
  belongs_to :posting, optional: true

  KINDS = %w[role company all describe draft review fit].freeze
  STATUSES = %w[queued running done failed].freeze
  ACTIVE = %w[queued running].freeze
  # Longer than any check takes (a ten-page list read by the LLM, or a 2,000-role
  # Workday board, take minutes): a run still active after this was cut off.
  STALE_AFTER = 1.hour
  # Everything takes longer: about 40 minutes for 133 companies (2026-10-05). So may weighing many roles' fit, each
  # description read first.
  ALL_STALE_AFTER = Authority::BATCH
  LONG = %w[all fit].freeze

  CUT_OFF = "Cut off: the server stopped before the check finished.".freeze
  # Whether a run's last word came before its cutoff.
  BEFORE_CUTOFF = "check_runs.updated_at < CASE WHEN check_runs.kind IN (:long) THEN CAST(:all AS timestamp) " \
                  "ELSE CAST(:one AS timestamp) END".freeze

  validates :kind, inclusion: { in: KINDS }
  validates :status, inclusion: { in: STATUSES }
  validates :requested_by, presence: true
  validates :posting, presence: true, if: -> { kind.in?(%w[role describe draft review]) }
  validates :company, presence: true, unless: -> { kind == "all" || (kind == "fit" && posting.nil?) }

  # Queued or running, and still within its time. A run past it will never finish (cut_off).
  scope :active, -> { where(status: ACTIVE).where.not(BEFORE_CUTOFF, cutoffs) }
  # Left queued or running past its time: active for over an hour (a batch's time for the long kinds), or, on an
  # in-process queue, left active by an earlier server process, whose queue went with it. Otherwise a restart
  # mid-check would block that role's next check for an hour.
  scope :cut_off, ->(booted_at: Rails.configuration.x.booted_at) { where(status: ACTIVE).where(BEFORE_CUTOFF, cutoffs(booted_at:)) }
  scope :newest_first, -> { order(created_at: :desc) }

  # A page reads a cut-off run as cut off, and writes nothing (review pass R5): its row says so once the next check
  # starts. Not at boot either: every process boots the app, the MCP server's too, and on an in-process queue its
  # boot would cut off the runs the web server is running.
  def self.abandon_stale!(booted_at: Rails.configuration.x.booted_at)
    cut_off(booted_at:).update_all(status: "failed", error: CUT_OFF, finished_at: Time.current, updated_at: Time.current)
  end

  # The time before which an active run will never finish: an hour ago, or a batch's time for the long kinds; on an
  # in-process queue, no earlier than this server process's start.
  def self.cutoff(long:, booted_at: Rails.configuration.x.booted_at)
    [ (long ? ALL_STALE_AFTER : STALE_AFTER).ago, (booted_at if in_process_queue?) ].compact.max
  end

  def self.cutoffs(booted_at: Rails.configuration.x.booted_at)
    { long: LONG, all: cutoff(long: true, booted_at:), one: cutoff(long: false, booted_at:) }
  end

  def self.in_process_queue? = CheckNowJob.queue_adapter.is_a?(ActiveJob::QueueAdapters::AsyncAdapter)

  # The check of a role or a company already under way, or a new one queued, with
  # what it could cost: one at a time per role and per company.
  def self.start_for!(record, requested_by: AuditEvent::OPERATOR)
    abandon_stale!
    role = record.is_a?(Posting)
    runs = role ? where(posting: record, kind: "role") : where(company: record, kind: "company")
    runs.active.first || create!(
      kind: role ? "role" : "company", company: role ? record.company : record, posting: (record if role),
      requested_by: requested_by, ceiling_usd: Verifier::CheckNow.ceiling(record)
    ).tap { |run| CheckNowJob.perform_later(run) }
  end

  # A role's description read (2b), or the read already under way: free, so no ceiling.
  def self.start_describe!(posting, requested_by: AuditEvent::OPERATOR)
    abandon_stale!
    where(kind: "describe", posting: posting).active.first || create!(
      kind: "describe", company: posting.company, posting: posting, requested_by: requested_by, ceiling_usd: 0
    ).tap { |run| CheckNowJob.perform_later(run) }
  end

  # A draft for `application` (2c), or the one already being written: one at a time per
  # application, with what a draft costs on the record. `request` is what to write.
  def self.start_draft!(application, kind:, language: nil, guidance: nil, contact: nil, requested_by: AuditEvent::OPERATOR)
    abandon_stale!
    where(kind: "draft", posting: application.posting).active.first || create!(
      kind: "draft", company: application.company, posting: application.posting, requested_by: requested_by,
      ceiling_usd: Drafts.estimate, request: { "kind" => kind, "language" => language, "guidance" => guidance, "contact_id" => contact&.id }
    ).tap { |run| CheckNowJob.perform_later(run) }
  end

  # A resume review for `application` (2d), or the one already being written: one at a time per application,
  # with what a review costs on the record. `request` holds the language asked.
  def self.start_review!(application, language: nil, requested_by: AuditEvent::OPERATOR)
    abandon_stale!
    where(kind: "review", posting: application.posting).active.first || create!(
      kind: "review", company: application.company, posting: application.posting, requested_by: requested_by,
      ceiling_usd: ResumeReviews.estimate, request: { "language" => language }
    ).tap { |run| CheckNowJob.perform_later(run) }
  end

  # The fit of `postings` weighed against the resume (2f), or the weighing already under way: one at a time, since a
  # batch reads descriptions first. One role's run is that role's; a batch's (from the Roles page, even of one role)
  # names its roles in `request` alone.
  def self.start_fit!(postings, batch: postings.size > 1, requested_by: AuditEvent::OPERATOR)
    abandon_stale!
    one = postings.first unless batch
    where(kind: "fit").active.first || create!(
      kind: "fit", company: one&.company, posting: one, requested_by: requested_by,
      ceiling_usd: (FitScores.estimate * postings.size).round(4), request: { "posting_ids" => postings.map(&:id) }
    ).tap { |run| CheckNowJob.perform_later(run) }
  end

  # Everything checked at once, or the run already under way: one at a time.
  def self.start_all!(requested_by: AuditEvent::OPERATOR)
    abandon_stale!
    where(kind: "all").active.first || create!(
      kind: "all", requested_by: requested_by, ceiling_usd: Verifier::CheckAll.plan.ceiling
    ).tap { |run| CheckNowJob.perform_later(run) }
  end

  def active? = ACTIVE.include?(status) && !cut_off?

  # Left active past its time, though its row may not say so yet.
  def cut_off?(booted_at: Rails.configuration.x.booted_at)
    ACTIVE.include?(status) && updated_at < self.class.cutoff(long: kind.in?(LONG), booted_at:)
  end

  def failed? = status == "failed" || cut_off?

  # Why it didn't finish.
  def failure = cut_off? ? CUT_OFF : error

  # How many roles a fit run weighs.
  def fit_size = Array(request["posting_ids"]).size

  # How many companies a check of everything has read so far, from its results file as the worker writes it.
  def progress
    return unless kind == "all" && run_id

    file = Rails.root.join("tmp/verifier", run_id, "results.jsonl")
    file.exist? ? file.each_line.count : 0
  end

  def target_name
    case kind
    when "role" then "#{posting&.role_title || 'a withdrawn role'} at #{company.name}"
    when "describe" then "the description of #{posting&.role_title || 'a withdrawn role'} at #{company.name}"
    when "draft" then "#{Draft::A_LABEL.fetch(request['kind'])} for #{posting&.role_title || 'a withdrawn role'} at #{company.name}"
    when "review" then "a resume review for #{posting&.role_title || 'a withdrawn role'} at #{company.name}"
    when "fit" then posting ? "the fit of #{posting.role_title} at #{company.name}" : "the fit of #{ActionController::Base.helpers.pluralize(fit_size, 'role')}"
    when "all" then "everything"
    else company.name
    end
  end
end
