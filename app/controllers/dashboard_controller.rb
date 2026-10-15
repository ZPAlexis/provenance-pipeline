class DashboardController < ApplicationController
  def show
    @applications = Application.group(:stage).count
    @roles = Overview.role_counts
    @tracking = Overview.tracking_counts
    @review = ReviewItem.open.count
    @stale = Overview.stale_count
    @changes = Overview.recent_changes
    @companies = Overview.companies
    @spend = Overview.spend
    CheckRun.abandon_stale!
    @runs = Overview.recent_runs
  end
end
