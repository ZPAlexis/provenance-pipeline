# Runs a check the operator asked for from the pages (a role, a company,
# everything, a description read, or a draft written), and keeps its outcome on
# the CheckRun the page polls. One at a time: development runs jobs on a single
# in-process thread, so politeness per site holds across checks.
class CheckNowJob < ApplicationJob
  queue_as :default

  def perform(check_run)
    return unless check_run.status == "queued"

    check_run.update!(status: "running", started_at: Time.current)
    DatabaseBackup.daily unless check_run.kind == "all" # everything backs up in full: it writes many verdicts
    outcome =
      case check_run.kind
      when "all" then Verifier::CheckAll.run!(check_run)
      when "describe"
        role = check_run.posting
        Verifier::Descriptions.read!(role, purpose: "describe: #{role.role_title} at #{role.company.name}",
                                           issued_by: check_run.requested_by).sole
      when "draft"
        asked = check_run.request
        Drafts.write!(check_run.posting.application, kind: asked["kind"], language: asked["language"],
                                                     guidance: asked["guidance"], issued_by: check_run.requested_by)
      when "role" then Verifier::CheckNow.role(check_run.posting)
      else Verifier::CheckNow.company(check_run.company)
      end
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
