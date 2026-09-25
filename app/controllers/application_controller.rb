class ApplicationController < ActionController::Base
  allow_browser versions: :modern
  stale_when_importmap_changes

  rescue_from ActiveRecord::RecordNotFound, with: :record_not_found

  private

  def record_not_found
    flash[:alert] = "The record you were looking for could not be found."

    redirect_back(fallback_location: root_path)
  end
end
