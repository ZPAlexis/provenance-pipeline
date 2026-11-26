# Where the search stands, and how it has gone (4e step 12: the dashboard and Analytics, one page): tabs for the
# pipeline, the watch and the agents, each what stands now on top and its history under it, since a day when given
# (the history alone). Read-only.
class DashboardController < ApplicationController
  TABS = %w[pipeline watch agents].freeze

  def show
    @tab = TABS.include?(params[:tab]) ? params[:tab] : "pipeline"
    @since = Date.iso8601(params[:since]) if params[:since].present?
    # Now.
    @applications = Application.group(:stage).count
    @roles = Overview.role_counts
    @tracking = Overview.tracking_counts
    @review = ReviewItem.open.count
    @companies = Overview.companies
    @spend = Overview.spend
    @runs = Overview.recent_runs
    @list_ages = Verifier::CheckAll.ages # how current the lists are (4e); the check itself is on the Roles page
    # How it has gone (3.3), since @since.
    @pipeline = Analytics.pipeline(since: @since)
    @watch = Analytics.watch(since: @since)
    @agents = Analytics.agents(since: @since)
  rescue Date::Error
    redirect_to root_path(tab: @tab), alert: "Since is a day as YYYY-MM-DD, not #{params[:since].inspect}.", status: :see_other
  end
end
