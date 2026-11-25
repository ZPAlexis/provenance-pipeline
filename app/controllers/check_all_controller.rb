# "Check all tracked companies" on the Roles page (1.4's "check everything", moved there and widened to every tracked
# company in 4e): the plan and the most it could cost, worked out after the page loads (it takes a moment), with how
# old the lists are, or the run under way.
class CheckAllController < ApplicationController
  def show
    @run = CheckRun.where(kind: "all").newest_first.first
    @plan = Verifier::CheckAll.plan unless @run&.active?
    @ages = Verifier::CheckAll.ages
  end

  def create
    unless Verifier::CheckAll.companies.exists?
      return redirect_to(roles_path, alert: "No company is tracked with a careers page to read yet.", status: :see_other)
    end

    CheckRun.start_all!
    redirect_to roles_path, notice: "Checking all tracked companies, in the background: its progress shows above.", status: :see_other
  end
end
