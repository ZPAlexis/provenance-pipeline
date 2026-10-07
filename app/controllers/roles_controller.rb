# The roles being watched: postings, in the operator's words.
class RolesController < ApplicationController
  TABS = %w[tracked suggested dismissed].freeze
  # The answers a tab can be narrowed to, in the order the filters show them.
  ANSWERS = %w[verified_live not_found inaccessible pending].freeze

  def index
    @tab = TABS.include?(params[:tab]) ? params[:tab] : "tracked"
    @answer = params[:answer] if ANSWERS.include?(params[:answer])
    @counts = Posting.group(:tracking).count
    roles = Posting.where(tracking: @tab)
    @answer_counts = roles.group(:verification_state).count
    roles = roles.where(verification_state: @answer) if @answer
    @roles = roles.joins(:company).includes(:company).order("companies.name", :role_title)
  end

  def show
    @role = Posting.includes(:company).find(params[:id])
    CheckRun.abandon_stale!
    @run = @role.check_runs.newest_first.first
    @history = @role.audit_events.order(occurred_at: :desc)
    # The checks whose matching said something about this role, newest first.
    @checks = @role.company.page_checks.where("matches @> ?", [ { posting_id: @role.id } ].to_json)
                   .order(checked_at: :desc).limit(10)
  end

  # The operator's watch list, through the same audited service as the rake
  # tasks. Undone by the opposite button, so no backup is taken first.
  def track = decide(:track!, "tracked")

  def dismiss = decide(:dismiss!, "dismissed")

  private

  def decide(change, done)
    role = Posting.includes(:company).find(params[:id])
    Verifier::Tracking.public_send(change, role, note: params[:note])
    redirect_back_or_to role_path(role), notice: "#{role.role_title} at #{role.company.name}: #{done}.", status: :see_other
  rescue ArgumentError => e
    redirect_back_or_to role_path(role), alert: "#{role.role_title}: #{e.message}", status: :see_other
  end
end
