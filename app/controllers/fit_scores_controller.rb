# Weighing roles' fit from the pages (Stage 2f): one role from its page, or every unscored role offered (tracked or
# suggested, not known to be gone) that has a description or a page to read one from, from the Roles page. Since 4c,
# also those weighed before the background as it is now, again (`before_background`); since 4d, those weighed before
# the screen check (`before_screen`). Runs in the background, one weighing at a time, with what it could cost asked
# first on the page.
class FitScoresController < ApplicationController
  # What each "weigh again" picks, and what it says when there is none.
  AGAIN = {
    "before_background" => "every role weighed has a Background fit read against your background as it is",
    "before_screen" => "every role weighed had its must-haves read"
  }.freeze

  def create
    role = Posting.includes(:company).find(params[:posting_id]) if params[:posting_id].present?
    again = AGAIN.keys.find { |key| params[key] == "1" }
    roles = if role then [ role ]
    else
      offered = FitScores.offered.includes(:company).order(:created_at).to_a
      FitScores.weighable(again ? FitScores.public_send(again, offered) : FitScores.unscored(offered))
    end
    # From an application's page (4e), back to it; from a role's page, back to its fit.
    back = if role&.application && params[:from] == "application" then application_path(role.application, anchor: "fit")
    elsif role then role_path(role, anchor: "fit")
    else roles_path(sort: "fit")
    end
    if (why = refusal(role, roles, again))
      return redirect_to back, alert: "Not weighed: #{why}.", status: :see_other
    end

    CheckRun.start_fit!(roles, batch: role.nil?)
    redirect_to back, status: :see_other
  end

  private

  def refusal(role, roles, again)
    return AGAIN.fetch(again) { "every role offered has a current score, or no description to weigh" } if role.nil? && roles.empty?
    return "#{role.role_title} has no description to weigh, nor a page of its own to read one from" if role && FitScores.weighable(roles).empty?

    FitScores.refusal(roles)
  end
end
