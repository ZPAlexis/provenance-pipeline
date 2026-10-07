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

  def show
    @company = Company.find(params[:id])
    CheckRun.abandon_stale!
    @run = @company.check_runs.where(kind: "company").newest_first.first
    @roles = @company.postings.order(:tracking, :role_title)
    @checks = @company.page_checks.order(checked_at: :desc).limit(10)
    @events = @company.audit_events.order(occurred_at: :desc).limit(10)
  end
end
