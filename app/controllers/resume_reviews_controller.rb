# An application's resume reviews (Stage 2d): written by the drafter in the background (a check run of kind
# review), or saved by the operator's own Claude client through MCP; deleted here by the operator alone,
# audited by their counts and hashes.
class ResumeReviewsController < ApplicationController
  def create
    application = Application.includes(:company, :posting).find(params[:application_id])
    language = params[:language].to_s.strip.presence
    if (why = ResumeReviews.refusal(application, language:))
      return redirect_to(application_path(application), alert: "Not reviewed: #{why}.", status: :see_other)
    end

    CheckRun.start_review!(application, language:)
    redirect_to application_path(application), status: :see_other
  end

  def destroy
    review = ResumeReview.find_by!(id: params[:id], application_id: params[:application_id])
    ResumeReviews.delete!(review)
    redirect_to application_path(review.application_id), notice: "Resume review deleted.", status: :see_other
  end
end
