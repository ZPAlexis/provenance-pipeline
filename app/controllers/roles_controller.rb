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
  # "Add a role" (1.5d; 4a): tracked as the operator, and checked only when they ask ("Add and check"), what that
  # could cost asked first; without a check its title is needed. From a company's page it is added there, and the
  # page stays open to add another; otherwise, or to follow its check, the role's page opens.
  def create
    company = Company.find(params[:company_id]) if params[:company_id].present?
    check = params[:check] == "1"
    placed = Verifier::Capture.role!(link: params[:link], title: params[:title], location: params[:location], source: params[:source],
                                     company_name: params[:company_name], company: company, check: check)
    role = placed.posting
    if check
      why = Verifier::CheckNow.refusal(role)
      CheckRun.start_for!(role) unless why
      checked = why ? " Not checked: #{why}" : " Checking it now: its own page first."
    end
    back = company && !check ? company_path(company) : role_path(role)
    redirect_to back, notice: "#{placed.note}#{checked}", status: :see_other
  rescue ArgumentError, ActiveRecord::RecordInvalid => e
    redirect_to company ? company_path(company, add_role: 1) : roles_path(add: 1), alert: "#{e.message.upcase_first.delete_suffix('.')}.",
                                                                                 status: :see_other
  end

  # The role's own page, as the operator gives it (4a): the link each check tries first.
  def own_page
    role = Posting.find(params[:id])
    Verifier::Capture.own_page!(role, params[:link], note: params[:note])
    redirect_to role_path(role), notice: "Its own page is now #{role.job_url}.", status: :see_other
  rescue ArgumentError, ActiveRecord::RecordInvalid => e
    redirect_to role_path(role, own_page: 1), alert: "#{e.message.upcase_first.delete_suffix('.')}.", status: :see_other
  end

  def show
    @role = Posting.includes(:company).find_by(id: params[:id]) or return withdrawn
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

  def dismiss = decide(:dismiss!, "archived")

  # Several roles archived ("dismissed", stored) at once, under one note, each audited on its own: all or none.
  # Backed up first (at most daily), since undoing many is many clicks.
  def dismiss_many
    roles = Posting.includes(:company).where(id: Array(params[:ids])).to_a
    return redirect_back_or_to(roles_path, alert: "Select the roles to archive first.", status: :see_other) if roles.empty?

    DatabaseBackup.daily
    ApplicationRecord.transaction { roles.each { |role| Verifier::Tracking.dismiss!(role, note: params[:note]) } }
    redirect_back_or_to roles_path, notice: "#{roles.size} #{'role'.pluralize(roles.size)} archived: never checked or suggested again.",
                                    status: :see_other
  rescue ArgumentError => e
    redirect_back_or_to roles_path, alert: "None archived: #{e.message}.", status: :see_other
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
