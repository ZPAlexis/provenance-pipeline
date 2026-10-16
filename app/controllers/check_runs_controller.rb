# "Check now" from the pages: queues a check of one role or one company, and
# answers the page's polling until it is done.
class CheckRunsController < ApplicationController
  def create
    record = params[:posting_id] ? Posting.includes(:company).find(params[:posting_id]) : Company.find(params[:company_id])
    back = record.is_a?(Posting) ? role_path(record) : company_path(record)
    return describe(record, back) if params[:describe].present? && record.is_a?(Posting)
    if (why = Verifier::CheckNow.refusal(record))
      return redirect_to back, alert: why, status: :see_other
    end

    CheckRun.start_for!(record)
    redirect_to back, status: :see_other
  end

  # The run as a Turbo Frame, for the page to poll; `poll` marks a reply to polling,
  # so a finished run tells the page to reload once with its new answer. Polled
  # from a review item, a finished run says instead whether it settled the item.
  def show
    run = CheckRun.find(params[:id])
    item = ReviewItem.find_by(id: params[:review_item_id]) if params[:review_item_id].present?
    render partial: "check_runs/run", locals: { run: run, poll: params[:poll].present?, item: item }
  end

  private

  # A role's description read in the background (2b): free, and refused only when it has no page of its own.
  def describe(role, back)
    return redirect_to(back, alert: Verifier::Descriptions::NO_PAGE, status: :see_other) if role.job_url.blank?

    CheckRun.start_describe!(role)
    redirect_to back, status: :see_other
  end
end
