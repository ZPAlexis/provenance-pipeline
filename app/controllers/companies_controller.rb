class CompaniesController < ApplicationController
  # The Companies page's tabs and filters (4a), shared with the MCP client's list_companies (WatchList).
  TABS = WatchList::TABS
  FILTERS = WatchList::FILTERS

  def index
    @tab = TABS.key?(params[:tab]) ? params[:tab] : "tracked"
    @filter = params[:filter] if FILTERS.key?(params[:filter])
    @q = params[:q].to_s.strip.presence
    found = Company.matching(@q) # every company when nothing is typed
    @counts, @filter_counts = WatchList.counts(found, @tab)
    @companies = WatchList.narrow(WatchList.in_tab(found, @tab), @filter).order(:name).to_a
    ids = @companies.map(&:id)
    # Per company: its roles by tracking and answer, its newest application, and when it was last verified.
    @roles = WatchList.role_counts(ids)
    @applications = WatchList.applications(ids)
    @last_checked = WatchList.last_checked(ids)
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

  # "Add a company" (1.5d; 4a): its domain, careers page, or ATS board, added as the operator, with its careers page
  # watched as given when they give one; read only when they ask ("Add and read"), what it could cost asked first.
  def create
    added = Verifier::Capture.company!(params[:link], name: params[:name], page: params[:careers_page])
    company = added.company
    if params[:read] == "1"
      why = Verifier::CheckNow.refusal(company)
      CheckRun.start_for!(company) unless why
      read = if why then " Not read: #{why}"
      elsif company.resolution_status == "resolved" then " Reading its careers page now."
      else " Finding its careers page and reading its roles now."
      end
    elsif company.resolution_status.in?([ nil, "failed" ]) # a page to confirm says so already
      read = " Not watched until its careers page is found: check it now, or set it by hand, below."
    end
    redirect_to company_path(company), notice: "#{added.note}#{read}", status: :see_other
  rescue ArgumentError, ActiveRecord::RecordInvalid => e
    redirect_to companies_path(tab: "all"), alert: "#{e.message.upcase_first.delete_suffix('.')}.", status: :see_other
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

  def decide(done = "Its careers page is watched: check it now to read its roles.")
    company = Company.find(params[:id])
    yield company
    redirect_to company_path(company), notice: done, status: :see_other
  rescue ArgumentError, Verifier::Candidates::NotACandidate, ActiveRecord::RecordInvalid => e
    redirect_to company_path(company), alert: e.message.upcase_first, status: :see_other
  end
end
