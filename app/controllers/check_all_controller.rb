# "Check everything" on the dashboard (1.4): the plan and the most it could cost,
# worked out after the page loads (it takes a moment), or the run under way.
class CheckAllController < ApplicationController
  def show
    CheckRun.abandon_stale!
    @run = CheckRun.where(kind: "all").newest_first.first
    @plan = Verifier::CheckAll.plan unless @run&.active?
  end

  def create
    return redirect_to(root_path, alert: "No watched company has a role on record yet.", status: :see_other) unless Verifier::CheckAll.companies.exists?

    CheckRun.start_all!
    redirect_to root_path, notice: "Checking everything, in the background: its progress shows below.", status: :see_other
  end
end
