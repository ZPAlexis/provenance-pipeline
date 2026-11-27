# Runs a check the operator asked for from the pages (a role, a company,
# everything, a description read, a draft or a review written, roles' fit weighed), and keeps its outcome on
# the CheckRun the page polls. One at a time: development runs jobs on a single
# in-process thread, so politeness per site holds across checks.
class CheckNowJob < ApplicationJob
  queue_as :default

  def perform(check_run)
    return unless check_run.status == "queued"
    # Its time ran out while it waited: the pages already call it cut off, so it stays so.
    return check_run.update!(status: "failed", error: CheckRun::CUT_OFF, finished_at: Time.current) if check_run.cut_off?

    check_run.update!(status: "running", started_at: Time.current)
    DatabaseBackup.daily unless check_run.kind == "all" # everything backs up in full: it writes many verdicts
    outcome =
      case check_run.kind
      when "all" then Verifier::CheckAll.run!(check_run)
      when "describe"
        role = check_run.posting
        Verifier::Descriptions.read!(role, purpose: "describe: #{role.role_title} at #{role.company.name}",
                                           issued_by: check_run.requested_by).sole
      when "review"
        ResumeReviews.write!(check_run.posting.application, language: check_run.request["language"], issued_by: check_run.requested_by)
      when "draft"
        asked = check_run.request
        application = check_run.posting.application
        Drafts.write!(application, kind: asked["kind"], language: asked["language"], guidance: asked["guidance"],
                                   contact: application.company.contacts.find_by(id: asked["contact_id"]), issued_by: check_run.requested_by)
      when "fit"
        # Descriptions first, for the roles with a page of their own but none on record (free); then the weighing.
        roles = Posting.includes(:company).where(id: check_run.request["posting_ids"]).to_a
        missing = FitScores.undescribed(roles)
        Verifier::Descriptions.read!(missing, purpose: "fit: descriptions to weigh", issued_by: check_run.requested_by) if missing.any?
        FitScores.weigh!(roles, issued_by: check_run.requested_by)
      when "links" then ProfileLinks.read!(SearchProfile.current&.profile_links.to_a, issued_by: check_run.requested_by)
      # Each credential its runs hold says who asked (4e step 12): the operator, or their AI assistant. A free check (4f)
      # calls no AI: a page that needs reading is left for their assistant.
      when "role" then Verifier::CheckNow.role(check_run.posting, issued_by: check_run.requested_by, free: check_run.free?)
      else
        if check_run.board_read?
          Verifier::BoardRead.run!(check_run.company, issued_by: check_run.requested_by)
        else
          Verifier::CheckNow.company(check_run.company, issued_by: check_run.requested_by, free: check_run.free?)
        end
      end
    moved = reread_moved(check_run) if check_run.kind.in?(%w[all role company])
    check_run.update!(
      status: outcome.finished? ? "done" : "failed", finished_at: Time.current,
      answer: outcome.answer, summary: [ outcome.summary, moved ].compact.join(" "), tally: outcome.tally, cost_usd: outcome.cost_usd,
      run_id: outcome.run_id, error: (outcome.summary unless outcome.finished?)
    )
  rescue StandardError => e
    # Whatever went wrong is the run's answer: the page shows it rather than waiting forever.
    Rails.logger.error("CheckNowJob #{check_run.id}: #{e.class}: #{e.message}")
    check_run.update!(status: "failed", finished_at: Time.current, error: "#{e.class.name.demodulize}: #{e.message}".truncate(500))
  end

  private

  # A check may move a role's own page, to the posting its link or its careers page led to (4e): the descriptions read
  # from the page before are read again from the new one, free. Never fails the check: a read that breaks is said.
  def reread_moved(check_run)
    roles = case check_run.kind
    when "all" then Posting.not_dismissed.where(company: Verifier::CheckAll.companies).preload(:company)
    when "role" then Posting.where(id: check_run.posting_id).preload(:company) # as the check left it
    else check_run.company.postings.not_dismissed.preload(:company)
    end
    Verifier::Descriptions.reread_moved!(roles, issued_by: check_run.requested_by)
  rescue StandardError => e
    Rails.logger.error("CheckNowJob #{check_run.id}, descriptions read again: #{e.class}: #{e.message}")
    "The descriptions read from a page no longer their role's own were not read again (#{e.class.name.demodulize})."
  end
end
