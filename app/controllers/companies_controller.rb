class CompaniesController < ApplicationController
  # The Companies page's tabs (4a): the companies the operator tracks, those archived ("dismissed", the stored word),
  # and all of them.
  TABS = { "tracked" => "Tracked", "dismissed" => "Archived", "all" => "All" }.freeze
  # What needs a look within a tab, each with what it holds said on hover: no careers page found yet, one found at
  # low confidence to confirm, no role tracked, or roles tracked of which none was still listed at its last check. The
  # last two never overlap: "listed" is a tracked role's answer, as in the Roles column.
  FILTERS = {
    "no_page" => [ "No careers page yet", "Never looked for, or none found", lambda { |scope|
      scope.where(resolution_status: [ nil, "failed" ])
    } ],
    "to_confirm" => [ "Page to confirm", "A careers page found at low confidence, held for you to confirm", lambda { |scope|
      scope.resolution_candidates
    } ],
    "none_tracked" => [ "No role tracked", "No role tracked there (a suggestion may be)", lambda { |scope|
      scope.where.not(id: Posting.tracked.select(:company_id))
    } ],
    "none_listed" => [ "None still listed", "Roles tracked there, but none still listed at its last check: gone, or no answer yet", lambda { |scope|
      scope.where(id: Posting.tracked.select(:company_id)).where.not(id: Posting.tracked.live.select(:company_id))
    } ]
  }.freeze

  def index
    @tab = TABS.key?(params[:tab]) ? params[:tab] : "tracked"
    @filter = params[:filter] if FILTERS.key?(params[:filter])
    @q = params[:q].to_s.strip.presence
    found = Company.matching(@q) # every company when nothing is typed
    @counts = TABS.keys.to_h { |tab| [ tab, in_tab(found, tab).count ] }
    tabbed = in_tab(found, @tab)
    @filter_counts = FILTERS.transform_values { |(*, narrow)| narrow.call(tabbed).count }
    @companies = (@filter ? FILTERS.fetch(@filter).last.call(tabbed) : tabbed).order(:name).to_a
    ids = @companies.map(&:id)
    # Per company: its roles by tracking and answer, its newest application, and when it was last verified.
    @roles = Posting.where(company_id: ids).group(:company_id, :tracking, :verification_state).count
    @applications = Application.where(company_id: ids).order(:stage_changed_on).group_by(&:company_id)
                               .transform_values { |list| list.select(&:open?).last || list.last }
    @last_checked = PageCheck.where(purpose: "verification", company_id: ids).group(:company_id).maximum(:checked_at)
  end

  # The operator's companies (4a), through the same audited service as the commands: archived with its roles in
  # play, or tracked again with the roles archived with it (unless asked not to).
  def track
    company = Company.find(params[:id])
    back = Verifier::Tracking.track_company!(company, note: params[:note], with_roles: params[:with_roles] == "1")
    redirect_to company_path(company), notice: "#{company.name}: tracked#{", #{helpers.pluralize(back.size, 'role')} back with it" if back.any?}.",
                                       status: :see_other
  rescue ArgumentError => e
    redirect_to company_path(company), alert: "#{e.message.upcase_first}.", status: :see_other
  end

  def dismiss
    company = Company.find(params[:id])
    roles = Verifier::Tracking.dismiss_company!(company, note: params[:note])
    redirect_to company_path(company), notice: "#{company.name}: archived#{", #{helpers.pluralize(roles.size, 'role')} in play with it" if roles.any?}. " \
                                               "Never checked, suggested from or reviewed, until you track it again.", status: :see_other
  rescue ArgumentError => e
    redirect_to company_path(company), alert: "#{e.message.upcase_first}.", status: :see_other
  end

  # Several companies archived at once, under one note, each with its roles and on the record: all or none. Backed
  # up first (at most daily), since undoing many is many clicks.
  def dismiss_many
    companies = Company.where(id: Array(params[:ids])).order(:name).to_a
    return redirect_back_or_to(companies_path, alert: "Select the companies to archive first.", status: :see_other) if companies.empty?

    DatabaseBackup.daily
    roles = ApplicationRecord.transaction { companies.sum { |company| Verifier::Tracking.dismiss_company!(company, note: params[:note]).size } }
    redirect_back_or_to companies_path, notice: "#{helpers.pluralize(companies.size, 'company')} archived, with #{helpers.pluralize(roles, 'role')} " \
                                                "in play: never checked, suggested from or reviewed, until you track one again.",
                                        status: :see_other
  rescue ArgumentError => e
    redirect_back_or_to companies_path, alert: "None archived: #{e.message}.", status: :see_other
  end

  # "Add a company": its domain, careers page, or ATS board, added as the operator
  # and read right away (its careers page found first), what it could cost shown before.
  def create
    added = Verifier::Capture.company!(params[:link], name: params[:name])
    company = added.company
    if company.resolution_status != "resolved" && Verifier::CheckNow.refusal(company).nil?
      CheckRun.start_for!(company)
      started = " Finding its careers page and reading its roles now."
    end
    redirect_to company_path(company), notice: "#{added.note}#{started}", status: :see_other
  rescue ArgumentError, ActiveRecord::RecordInvalid => e
    redirect_to companies_path(tab: "all"), alert: e.message.upcase_first, status: :see_other
  end

  # A careers page found at low confidence, decided by the operator; or the right one set by hand.
  # Audited as theirs (Verifier::Candidates). Reading its roles is the Check now beside it.
  def confirm_page
    decide { |company| Verifier::Candidates.confirm!(company) }
  end

  def reject_page
    decide("Rejected: set the right page by hand if you know it.") { |company| Verifier::Candidates.reject!(company) }
  end

  def set_page
    decide { |company| Verifier::Candidates.set_page!(company, params[:url].to_s.strip, reasoning: params[:note]) }
  end

  # The company's name as the operator gives it: a name guessed from a domain is often not quite it.
  def rename
    decide("Renamed.") do |company|
      ApplicationRecord.transaction do
        company.update!(name: params[:name].to_s.strip)
        AuditEvent.record_write!(company, actor: AuditEvent::OPERATOR, reasoning: "Renamed by hand.")
      end
    end
  end

  def show
    @company = Company.find(params[:id])
    @run = @company.check_runs.where(kind: "company").newest_first.first
    @roles = @company.postings.order(:tracking, :role_title)
    @checks = @company.page_checks.order(checked_at: :desc).limit(10)
    @events = @company.audit_events.order(occurred_at: :desc).limit(10).includes(:credential)
    @contacts = @company.contacts.includes(applications: :posting)
    # What tracking or archiving it would do: its roles in play, an open application that stops archiving, and the
    # roles that would come back with it.
    @in_play = @company.postings.not_dismissed.count
    @open_application = @company.applications.open.includes(:posting).first
    @archived_with = @company.dismissed? ? Verifier::Tracking.archived_with(@company).size : 0
  end

  private

  def in_tab(scope, tab) = tab == "all" ? scope : scope.where(tracking: tab)

  def decide(done = "Its careers page is watched: check it now to read its roles.")
    company = Company.find(params[:id])
    yield company
    redirect_to company_path(company), notice: done, status: :see_other
  rescue ArgumentError, Verifier::Candidates::NotACandidate, ActiveRecord::RecordInvalid => e
    redirect_to company_path(company), alert: e.message.upcase_first, status: :see_other
  end
end
