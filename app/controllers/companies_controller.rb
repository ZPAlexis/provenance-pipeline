class CompaniesController < ApplicationController
  VIEWS = {
    "watched" => ->(scope) { scope.where(resolution_status: "resolved") },
    "candidates" => ->(scope) { scope.resolution_candidates },
    "unresolved" => ->(scope) { scope.where(resolution_status: [ nil, "failed" ]) },
    "all" => ->(scope) { scope }
  }.freeze

  def index
    @view = VIEWS.key?(params[:view]) ? params[:view] : "watched"
    @counts = VIEWS.transform_values { |filter| filter.call(Company.all).count }
    @companies = VIEWS.fetch(@view).call(Company.order(:name))
    # Per company: its roles still in play by answer, and when it was last verified.
    @roles = Posting.not_dismissed.group(:company_id, :verification_state).count
    @last_checked = PageCheck.where(purpose: "verification").group(:company_id).maximum(:checked_at)
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
    redirect_to companies_path(view: "all"), alert: e.message.upcase_first, status: :see_other
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
    CheckRun.abandon_stale!
    @run = @company.check_runs.where(kind: "company").newest_first.first
    @roles = @company.postings.order(:tracking, :role_title)
    @checks = @company.page_checks.order(checked_at: :desc).limit(10)
    @events = @company.audit_events.order(occurred_at: :desc).limit(10)
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
