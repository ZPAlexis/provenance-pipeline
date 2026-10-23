# An application's activity, corrected or deleted from its timeline (2a). The
# operator's alone, through Pipeline: audited, a deleted one's record keeping all it said.
class ActivitiesController < ApplicationController
  include DayParam

  before_action { @activity = Activity.find_by!(id: params[:id], application_id: params[:application_id]) }

  def update
    contact = (@activity.application.company.contacts.find(params[:contact_id]) if params[:contact_id].present?)
    edited = Pipeline.edit_activity!(@activity, kind: params[:kind], summary: params[:summary], on: day, contact: contact)
    back(notice: edited ? "Activity saved." : "Nothing to save: it says the same as before.")
  rescue ArgumentError, ActiveRecord::RecordInvalid => e
    back(alert: "Not saved: #{e.message}.")
  end

  def destroy
    Pipeline.delete_activity!(@activity)
    back(notice: "Activity deleted.")
  end

  private

  def back(**flash) = redirect_to(application_path(@activity.application_id), status: :see_other, **flash)
end
