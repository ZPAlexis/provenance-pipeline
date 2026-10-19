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
  end

  def show
    @timeline = Pipeline.timeline(@application)
  end

  def create
    role = Posting.includes(:company).find(params[:posting_id])
    application = Pipeline.start!(role, stage: params[:stage], on: day, note: params[:note])
    CheckRun.start_describe!(role) if role.job_url # what the drafting to come reads: free, in the background
    redirect_to application_path(application), notice: "Application started at #{Application.stage_label(application.stage)}.",
                                               status: :see_other
  rescue ArgumentError, ActiveRecord::RecordInvalid => e
    redirect_back_or_to role_path(role), alert: "Not started: #{e.message}.", status: :see_other
  end

  def move
    act do
      Pipeline.move!(@application, params[:stage], on: day, note: params[:note])
      "Moved to #{Application.stage_label(@application.stage)}."
    end
  end

  def log
    act do
      activity = Pipeline.log!(@application, kind: params[:kind], summary: params[:summary], on: day)
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

  def find_application
    @application = Application.includes(:company, :posting, :activities).find(params[:id])
  end

  # Makes the write in the block, then back to the application with what it did, or why not.
  def act
    redirect_to application_path(@application), notice: yield, status: :see_other
  rescue ArgumentError, ActiveRecord::RecordInvalid => e
    redirect_to application_path(@application), alert: e.message.upcase_first, status: :see_other
  end
end
