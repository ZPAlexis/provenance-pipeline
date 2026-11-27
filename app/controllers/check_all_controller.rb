# "Check all tracked companies" on the Roles page (1.4's "check everything", moved there and widened to every tracked
# company in 4e): the plan and the most it could cost, worked out after the page loads (it takes a moment), with how
# old the lists are, or the run under way.
class CheckAllController < ApplicationController
  def show
    @run = CheckRun.where(kind: "all").newest_first.first
    @plan = Verifier::CheckAll.plan unless @run&.active?
    @ages = Verifier::CheckAll.ages
    @to_read = Verifier::PagesToRead.list # what a free check left unread (4f)
  end

  # `mode=free` (4f): a free check, no AI anywhere, the pages that need reading left for the AI assistant; every check
  # is one when no API key is set.
  def create
    unless Verifier::CheckAll.companies.exists?
      return redirect_to(roles_path, alert: "No company is tracked with a careers page to read yet.", status: :see_other)
    end

    run = CheckRun.start_all!(free: params[:mode] == "free")
    said = run.free? ? "A free check of all tracked companies, in the background: pages that need reading are left for your AI assistant." :
                       "Checking all tracked companies, in the background: its progress shows above."
    redirect_to roles_path, notice: said, status: :see_other
  end
end
