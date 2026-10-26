# Weighing roles' fit from the pages (Stage 2f): one role from its page, or every unscored role offered (tracked or
# suggested, not known to be gone) that has a description or a page to read one from, from the Roles page. Runs in
# the background, one weighing at a time, with what it could cost asked first on the page.
class FitScoresController < ApplicationController
  def create
    role = Posting.includes(:company).find(params[:posting_id]) if params[:posting_id].present?
    roles = role ? [ role ] : FitScores.weighable(FitScores.unscored(FitScores.offered.includes(:company).order(:created_at).to_a))
    back = role ? role_path(role, anchor: "fit") : roles_path(sort: "fit")
    if (why = refusal(role, roles))
      return redirect_to back, alert: "Not weighed: #{why}.", status: :see_other
    end

    CheckRun.start_fit!(roles, batch: role.nil?)
    redirect_to back, status: :see_other
  end

  private

  def refusal(role, roles)
    return "every role offered has a current score, or no description to weigh" if role.nil? && roles.empty?
    return "#{role.role_title} has no description to weigh, nor a page of its own to read one from" if role && FitScores.weighable(roles).empty?

    FitScores.refusal(roles)
  end
end
