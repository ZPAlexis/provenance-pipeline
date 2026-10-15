# The operator's applications (Stage 2a): the pipeline by stage, each
# application's page, and its forms. Every write goes through Pipeline, audited
# as the operator's; no agent can make any of them.
class ApplicationsController < ApplicationController
  # One line of an application's timeline: a stage it reached, or an activity.
  Entry = Data.define(:on, :at, :stage, :from, :activity, :note, :actor)

  before_action :find_application, only: %i[show move log note]

  def index
    applications = Application.includes(:company, :posting).order(stage_changed_on: :desc, updated_at: :desc).to_a
    @open = applications.select(&:open?).group_by(&:stage)
    @closed = applications.reject(&:open?)
    @latest = Activity.where(application_id: applications.map(&:id)).select("DISTINCT ON (application_id) activities.*")
                      .order(:application_id, occurred_on: :desc, created_at: :desc).index_by(&:application_id)
  end

  def show
    @timeline = timeline(@application)
  end

  def create
    role = Posting.includes(:company).find(params[:posting_id])
    application = Pipeline.start!(role, stage: params[:stage], on: day, note: params[:note])
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
      "Notes kept."
    end
  end

  private

  def find_application
    @application = Application.includes(:company, :posting, :activities).find(params[:id])
  end

  # The day it happened, as the operator says; today when not given.
  def day = params[:on].present? ? Date.iso8601(params[:on]) : Date.current

  # Makes the write in the block, then back to the application with what it did, or why not.
  def act
    redirect_to application_path(@application), notice: yield, status: :see_other
  rescue ArgumentError, ActiveRecord::RecordInvalid => e
    redirect_to application_path(@application), alert: e.message.upcase_first, status: :see_other
  end

  # Its stage changes (from the audit log) and its activities, newest first.
  def timeline(application)
    moves = application.audit_events.where("changes_made ? 'stage'").map do |event|
      Entry.new(on: Date.parse(event.changes_made.dig("stage_changed_on", 1).to_s), at: event.occurred_at,
                stage: event.changes_made.dig("stage", 1), from: event.changes_made.dig("stage", 0), activity: nil,
                note: event.reasoning, actor: event.actor)
    end
    activities = application.activities.map do |activity|
      Entry.new(on: activity.occurred_on, at: activity.created_at, stage: nil, from: nil, activity: activity,
                note: activity.summary, actor: activity.logged_by)
    end
    (moves + activities).sort_by { |entry| [ entry.on, entry.at ] }.reverse
  end
end
