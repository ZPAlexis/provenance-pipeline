# An application's resume reviews (Stage 2d): saved by the operator's own Claude client through MCP, deleted
# here by the operator alone, audited by their counts and hashes.
class ResumeReviewsController < ApplicationController
  def destroy
    review = ResumeReview.find_by!(id: params[:id], application_id: params[:application_id])
    ResumeReviews.delete!(review)
    redirect_to application_path(review.application_id), notice: "Resume review deleted.", status: :see_other
  end
end
