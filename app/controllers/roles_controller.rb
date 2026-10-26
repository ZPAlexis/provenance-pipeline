# The roles being watched: postings, in the operator's words.
class RolesController < ApplicationController
  TABS = %w[tracked suggested dismissed].freeze
  # The answers a tab can be narrowed to, in the order the filters show them.
  ANSWERS = %w[verified_live not_found inaccessible pending].freeze
  # The fit a list can be narrowed to (2f): at least this score, or not weighed yet.
  FITS = { "85" => "85 and up", "70" => "70 and up", "50" => "50 and up", "none" => "Not weighed" }.freeze

  def index
    @tab = TABS.include?(params[:tab]) ? params[:tab] : "tracked"
    @answer = params[:answer] if ANSWERS.include?(params[:answer])
    @q = params[:q].to_s.strip.presence
    found = Posting.matching(@q) # every role when nothing is typed
    @counts = found.group(:tracking).count
    roles = found.where(tracking: @tab)
    @answer_counts = roles.group(:verification_state).count
    roles = roles.where(verification_state: @answer) if @answer
    @roles = roles.includes(:company).order("companies.name", :role_title).to_a
    fits(@roles)
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
    @run = @role.check_runs.where(kind: "role").newest_first.first
    @describe_run = @role.check_runs.where(kind: "describe").newest_first.first
    @descriptions = @role.role_descriptions.newest_first.to_a
    @fit = FitScores.shown([ @role ])[@role.id]
    @earlier_fits = @role.fit_scores.newest_first.offset(1).limit(5).to_a
    @fit_run = CheckRun.where(kind: "fit").active.first || @role.check_runs.where(kind: "fit").newest_first.first
    @history = @role.audit_events.order(occurred_at: :desc).includes(:credential)
    # The checks whose matching said something about this role, newest first.
    @checks = @role.company.page_checks.where("matches @> ?", [ { posting_id: @role.id } ].to_json)
                   .order(checked_at: :desc).limit(10)
  end

  # The operator's watch list, through the same audited service as the rake
  # tasks. Undone by the opposite button, so no backup is taken first.
  def track = decide(:track!, "tracked")

  def dismiss = decide(:dismiss!, "dismissed")

  # Several roles dismissed at once, under one note, each audited on its own: all or none.
  # Backed up first (at most daily), since undoing many is many clicks.
  def dismiss_many
    roles = Posting.includes(:company).where(id: Array(params[:ids])).to_a
    return redirect_back_or_to(roles_path, alert: "Select the roles to dismiss first.", status: :see_other) if roles.empty?

    DatabaseBackup.daily
    ApplicationRecord.transaction { roles.each { |role| Verifier::Tracking.dismiss!(role, note: params[:note]) } }
    redirect_back_or_to roles_path, notice: "#{roles.size} #{'role'.pluralize(roles.size)} dismissed: never checked or suggested again.",
                                    status: :see_other
  rescue ArgumentError => e
    redirect_back_or_to roles_path, alert: "None dismissed: #{e.message}.", status: :see_other
  end

  private

  # Each listed role's newest fit (2f), the list narrowed by fit and sorted by it when asked, and what weighing the
  # unscored would take: the roles offered (tracked or suggested) with no current score and a description to weigh.
  def fits(roles)
    @fits = FitScores.shown(roles.map(&:id))
    @fit = params[:fit] if FITS.key?(params[:fit])
    @sort = "fit" if params[:sort] == "fit"
    at_least = ->(floor) { roles.count { |role| @fits[role.id] && @fits[role.id].score.score >= floor } }
    @fit_counts = FITS.keys.to_h { |key| [ key, key == "none" ? roles.count { |role| !@fits[role.id] } : at_least.call(key.to_i) ] }
    @roles = roles.select { |role| @fit == "none" ? !@fits[role.id] : @fits[role.id] && @fits[role.id].score.score >= @fit.to_i } if @fit
    @roles = @roles.sort_by.with_index { |role, index| [ -(@fits[role.id]&.score&.score || -1), index ] } if @sort
    @unscored = FitScores.weighable(FitScores.unscored(FitScores.offered.includes(:company).to_a))
    # Any weighing under way (one at a time), or the last batch for an hour after it ends.
    @fit_run = CheckRun.where(kind: "fit").active.first || CheckRun.where(kind: "fit", posting_id: nil).newest_first.first
    @fit_run = nil unless @fit_run && (@fit_run.active? || @fit_run.finished_at&.after?(1.hour.ago))
  end

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
