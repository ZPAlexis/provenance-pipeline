# The operator's applications (Stage 2a): the pipeline by stage, each
# application's page, and its forms. Every write goes through Pipeline, audited
# as the operator's; no agent can make any of them.
class ApplicationsController < ApplicationController
  include DayParam

  before_action :find_application, only: %i[show move log note]

  def index
    applications = Application.includes(:company, :posting).order(stage_changed_on: :desc, updated_at: :desc).to_a
    @open = applications.select(&:open?).group_by(&:stage)
    @closed = applications.reject(&:open?)
    @latest = Activity.where(application_id: applications.map(&:id)).select("DISTINCT ON (application_id) activities.*")
                      .order(:application_id, occurred_on: :desc, created_at: :desc).index_by(&:application_id)
    # Each card's role fit, and its company's beside it (4e): two scores, never weighed into each other.
    @fits = FitScores.shown(applications.map(&:posting_id))
    @company_fits = WatchList.reviews(applications.map(&:company_id).uniq)
  end

  def show
    @timeline = Pipeline.timeline(@application)
    @drafts = @application.drafts.includes(:llm_call, :revises, :resume, :role_description, :contact).newest_first.to_a
    @reviews = @application.resume_reviews.includes(:resume, :role_description, :llm_call).newest_first.to_a
    @review_run = @application.posting.check_runs.where(kind: "review").newest_first.first
    @draft_run = @application.posting.check_runs.where(kind: "draft").newest_first.first
    fit_and_history
  end

  def create
    role = Posting.includes(:company).find(params[:posting_id])
    application = Pipeline.start!(role, stage: params[:stage], on: day, note: params[:note])
    CheckRun.start_describe!(role) if role.job_url # what the drafter reads: free, in the background
    redirect_to application_path(application), notice: "Application started at #{Application.stage_label(application.stage)}.",
                                               status: :see_other
  rescue ArgumentError, ActiveRecord::RecordInvalid => e
    redirect_back_or_to role_path(role), alert: "Not started: #{e.message}.", status: :see_other
  end

  def move
    act do
      redating = @application.stage == params[:stage]
      Pipeline.move!(@application, params[:stage], on: day, note: params[:note])
      label = Application.stage_label(@application.stage)
      redating ? "#{label} re-dated to #{@application.stage_changed_on}." : "Moved to #{label}."
    end
  end

  def log
    act do
      activity = Pipeline.log!(@application, kind: params[:kind], summary: params[:summary], on: day, contact: contact)
      "Logged: #{activity.kind.humanize.downcase} on #{activity.occurred_on}."
    end
  end

  def note
    act do
      Pipeline.note!(@application, notes: params[:notes], comp_expectation: params[:comp_expectation])
      "Notes saved."
    end
  end

  private

  # The role's fit and its company's (4e), to work from this page alone, and every change to the application and what
  # was saved under it: its activities and contacts (by the application's id they record, so a deleted one shows too),
  # its drafts and its resume reviews, the AI assistant's included.
  def fit_and_history
    role = @application.posting
    @fit = FitScores.shown([ role ])[role.id]
    @earlier_fits = role.fit_scores.newest_first.offset(1).limit(5).to_a
    @descriptions = role.role_descriptions.newest_first.to_a
    @fit_run = CheckRun.where(kind: "fit").active.first || role.check_runs.where(kind: "fit").newest_first.first
    @company_review = CompanyReviews.newest(@application.company)
    @profile = SearchProfile.current
    under = AuditEvent.where(target_type: %w[Activity ApplicationContact])
                      .where("jsonb_exists(changes_made -> 'application_id', :id)", id: @application.id)
    @history = AuditEvent.where(target: @application).or(under)
                         .or(AuditEvent.where(target_type: "Draft", target_id: @application.drafts.select(:id)))
                         .or(AuditEvent.where(target_type: "ResumeReview", target_id: @application.resume_reviews.select(:id)))
                         .order(occurred_at: :desc).includes(:credential)
  end

  def find_application
    @application = Application.includes(:company, :posting, :activities).find(params[:id])
  end

  # The contact an activity was with: one of the application's company's, or none.
  def contact = (@application.company.contacts.find(params[:contact_id]) if params[:contact_id].present?)

  # Makes the write in the block, then back to the application with what it did, or why not.
  def act
    redirect_to application_path(@application), notice: yield, status: :see_other
  rescue ArgumentError, ActiveRecord::RecordInvalid => e
    redirect_to application_path(@application), alert: e.message.upcase_first, status: :see_other
  end
end
