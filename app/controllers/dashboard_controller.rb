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
    @runs = Overview.recent_runs
    @list_ages = Verifier::CheckAll.ages # how current the lists are (4e); the check itself is on the Roles page
  end
end
