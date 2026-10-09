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

  # "Add a role": its own page at the employer and its title, tracked as the operator's
  # choice, then checked right away (its company's careers page found first when it has none).
  def create
    placed = Verifier::Capture.role!(link: params[:link], title: params[:title], location: params[:location],
                                     source: params[:source], company_name: params[:company_name])
    role = placed.posting
    if Verifier::CheckNow.refusal(role).nil?
      CheckRun.start_for!(role)
      started = " Checking it now: its own page first."
    end
    redirect_to role_path(role), notice: "#{placed.note}#{started}", status: :see_other
  rescue ArgumentError, ActiveRecord::RecordInvalid => e
    redirect_to roles_path(add: 1), alert: e.message.upcase_first, status: :see_other
  end

  def show
    @role = Posting.includes(:company).find_by(id: params[:id]) or return withdrawn
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

  # A suggestion withdrawn since its page was opened (a check found it gone, or the
  # profile changed): its audit record says why.
  def withdrawn
    event = AuditEvent.find_by!(target_type: "Posting", target_id: params[:id], action: "destroy")
    title = event.changes_made.dig("role_title", 0)
    redirect_to roles_path(tab: "suggested"), alert: "#{title} is no longer suggested. #{event.reasoning}", status: :see_other
  end

  def decide(change, done)
    role = Posting.includes(:company).find(params[:id])
    Verifier::Tracking.public_send(change, role, note: params[:note])
    redirect_back_or_to role_path(role), notice: "#{role.role_title} at #{role.company.name}: #{done}.", status: :see_other
  rescue ArgumentError => e
    redirect_back_or_to role_path(role), alert: "#{role.role_title}: #{e.message}", status: :see_other
  end
end
