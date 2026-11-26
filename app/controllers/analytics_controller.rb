# How the search is going (3.3) is the dashboard's since 4e step 12: each of its sections a tab there. The page's old
# address leads to the dashboard, the day it was given kept; a link to a section (#watch, #agents) opens that tab.
class AnalyticsController < ApplicationController
  def index
    redirect_to root_path({ since: params[:since].presence }.compact), status: :moved_permanently
  end
end
