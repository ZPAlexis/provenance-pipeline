class CompaniesController < ApplicationController
  # The Companies page's tabs and filters (4a; 4b's fit and facts), shared with the MCP client's list_companies (WatchList).
  TABS = WatchList::TABS
  FILTERS = WatchList::FILTERS
  FITS = WatchList::FITS
  FACTS = WatchList::FACTS

  # Words and a review's facts narrow every count; within a tab, what needs a look (never on Suggested, where nothing is
  # watched yet), then the fit. Sorted by name, or best fit first.
  def index
    @tab = TABS.key?(params[:tab]) ? params[:tab] : "tracked"
    @filter = params[:filter] if FILTERS.key?(params[:filter]) && @tab != "suggested"
    @fit = params[:fit] if FITS.key?(params[:fit])
    @sort = "fit" if params[:sort] == "fit"
    @facts = FACTS.keys.to_h { |fact| [ fact, params[fact].to_s.strip ] }.compact_blank
    @q = params[:q].to_s.strip.presence
    @keep = { tab: @tab, filter: @filter, fit: @fit, sort: @sort, q: @q, **@facts.symbolize_keys }
    @profile = SearchProfile.current
    found = WatchList.by_facts(Company.matching(@q), @facts) # every company when nothing is typed or chosen
    @counts, @filter_counts = WatchList.counts(found, @tab)
    narrowed = WatchList.narrow(WatchList.in_tab(found, @tab), @filter)
    @fit_counts = WatchList.fit_counts(narrowed, profile: @profile)
    @companies = WatchList.by_fit(narrowed, @fit, profile: @profile).order(:name).to_a
    ids = @companies.map(&:id)
    # Per company: its newest review, its roles by tracking and answer, its newest application, and when it was last verified.
    @reviews = WatchList.reviews(ids)
    @companies = @companies.sort_by.with_index { |company, index| [ -(@reviews[company.id]&.score || -1), index ] } if @sort
    @reviewed = CompanyReview.exists?
    @fact_options = @reviewed ? WatchList.fact_options : {}
    @roles = WatchList.role_counts(ids)
    @applications = WatchList.applications(ids)
    @last_checked = WatchList.last_checked(ids)
  end

  # The operator's companies (4a), through the same audited service as the commands: archived with its roles in
  # play, or tracked again with the roles archived with it (unless asked not to).
  def track
    company = Company.find(params[:id])
    proposal = company.suggested?
    back = Verifier::Tracking.track_company!(company, note: params[:note], with_roles: params[:with_roles] == "1")
    read = (Verifier::BoardRead.link(company) ? " The board it was proposed with is being read now, free." : " Check now finds its careers page.") if proposal
    redirect_to company_path(company), notice: "#{company.name}: tracked#{", #{helpers.pluralize(back.size, 'role')} back with it" if back.any?}.#{read}",
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

  # Several proposals tracked at once (4b), under one note, each on the record: all or none. Each one's board is read
  # once the tracking commits, free, one after another. Backed up first (at most daily): undoing one archives it, which
  # declines it for good.
  def track_many
    companies = Company.suggested.where(id: Array(params[:ids])).order(:name).to_a
    if companies.empty?
      return redirect_back_or_to(companies_path(tab: "suggested"), alert: "Select the proposals to track first.", status: :see_other)
    end

    DatabaseBackup.daily
    ApplicationRecord.transaction { companies.each { |company| Verifier::Tracking.track_company!(company, note: params[:note], with_roles: false) } }
    redirect_back_or_to companies_path(tab: "suggested"), notice: "#{helpers.pluralize(companies.size, 'company')} tracked. #{reading(companies)}",
                                                          status: :see_other
  rescue ArgumentError => e
    redirect_back_or_to companies_path(tab: "suggested"), alert: "None tracked: #{e.message}.", status: :see_other
  end

  # Several companies archived at once, under one note, each with its roles and on the record: all or none. Backed
  # up first (at most daily), since undoing many is many clicks. A proposal archived is declined, for good.
  def dismiss_many
    companies = Company.where(id: Array(params[:ids])).order(:name).to_a
    return redirect_back_or_to(companies_path, alert: "Select the companies to archive first.", status: :see_other) if companies.empty?

    DatabaseBackup.daily
    proposals = companies.all?(&:suggested?)
    roles = ApplicationRecord.transaction { companies.sum { |company| Verifier::Tracking.dismiss_company!(company, note: params[:note]).size } }
    said = if proposals
      "#{helpers.pluralize(companies.size, 'proposal')} declined: archived, and never proposed again."
    else
      "#{helpers.pluralize(companies.size, 'company')} archived, with #{helpers.pluralize(roles, 'role')} " \
        "in play: never checked, suggested from or reviewed, until you track one again."
    end
    redirect_back_or_to companies_path, notice: said, status: :see_other
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
    # How well it fits the company preferences (4b): its newest review, and the scores before it.
    @profile = SearchProfile.current
    @review, *@earlier_reviews = @company.company_reviews.newest_first.limit(6).to_a
  end

  private

  # What tracking these proposals reads: the boards they were proposed with, free; Check now finds the others' pages.
  def reading(companies)
    read = companies.count { |company| Verifier::BoardRead.link(company) }
    rest = companies.size - read
    boards = if read == companies.size then companies.one? ? "Its board is" : "Their boards are"
    elsif read.positive? then "#{read} of their boards #{read == 1 ? 'is' : 'are'}"
    end
    pages = if rest == companies.size then "Check now finds #{companies.one? ? 'its careers page' : 'their careers pages'}."
    elsif rest.positive? then "Check now finds the careers #{rest == 1 ? 'page of the other one' : "pages of the other #{rest}"}."
    end
    [ ("#{boards} being read now, free#{', one after another' if read > 1}." if boards), pages ].compact.join(" ")
  end

  def decide(done = "Its careers page is watched: check it now to read its roles.")
    company = Company.find(params[:id])
    yield company
    redirect_to company_path(company), notice: done, status: :see_other
  rescue ArgumentError, Verifier::Candidates::NotACandidate, ActiveRecord::RecordInvalid => e
    redirect_to company_path(company), alert: e.message.upcase_first, status: :see_other
  end
end
