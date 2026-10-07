# Runs a check the operator asked for from the pages, and keeps its outcome on
# the CheckRun the page polls. One at a time: development runs jobs on a single
# in-process thread, so politeness per site holds across checks.
class CheckNowJob < ApplicationJob
  queue_as :default

  def perform(check_run)
    return unless check_run.status == "queued"

    check_run.update!(status: "running", started_at: Time.current)
    DatabaseBackup.daily
    outcome = check_run.kind == "role" ? Verifier::CheckNow.role(check_run.posting) : Verifier::CheckNow.company(check_run.company)
    check_run.update!(
      status: outcome.finished? ? "done" : "failed", finished_at: Time.current,
      answer: outcome.answer, summary: outcome.summary, tally: outcome.tally, cost_usd: outcome.cost_usd,
      run_id: outcome.run_id, error: (outcome.summary unless outcome.finished?)
    )
  rescue StandardError => e
    # Whatever went wrong is the run's answer: the page shows it rather than waiting forever.
    Rails.logger.error("CheckNowJob #{check_run.id}: #{e.class}: #{e.message}")
    check_run.update!(status: "failed", finished_at: Time.current, error: "#{e.class.name.demodulize}: #{e.message}".truncate(500))
  end
end
