# "Check now" from the pages: queues a check of one role or one company, and
# answers the page's polling until it is done.
class CheckRunsController < ApplicationController
  def create
    record = params[:posting_id] ? Posting.includes(:company).find(params[:posting_id]) : Company.find(params[:company_id])
    back = record.is_a?(Posting) ? role_path(record) : company_path(record)
    if (why = Verifier::CheckNow.refusal(record))
      return redirect_to back, alert: why, status: :see_other
    end

    CheckRun.start_for!(record)
    redirect_to back, status: :see_other
  end

  # The run as a Turbo Frame, for the page to poll; `poll` marks a reply to polling,
  # so a finished run tells the page to reload once with its new answer.
  def show
    run = CheckRun.find(params[:id])
    render partial: "check_runs/run", locals: { run: run, poll: params[:poll].present? }
  end
end
