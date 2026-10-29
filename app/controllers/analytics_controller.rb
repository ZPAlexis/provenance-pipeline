# How the search is going (3.3), worked out from the record. Read-only.
class AnalyticsController < ApplicationController
  def index
    @since = Date.iso8601(params[:since]) if params[:since].present?
    @pipeline = Analytics.pipeline(since: @since)
  rescue Date::Error
    redirect_to analytics_path, alert: "Since is a day as YYYY-MM-DD, not #{params[:since].inspect}.", status: :see_other
  end
end
