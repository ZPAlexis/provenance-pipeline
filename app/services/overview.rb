# What the dashboard's tiles show: where the tracked roles stand, the companies watched, the runs asked for lately,
# and what reading pages has cost. Read-only. (Since 4e step 12 the verdicts that changed are the audit log's.)
module Overview
  RECENT_RUNS = 8
  # A tracked role not checked for this long is worth a look: listings are read
  # in full every 14 days, so its answer may have gone stale.
  STALE_AFTER = 14.days

  module_function

  # Tracked roles by verification state.
  def role_counts
    Posting.tracked.group(:verification_state).count
  end

  def tracking_counts
    Posting.group(:tracking).count
  end


  def companies
    {
      watched: Company.watched.count,
      boards: Company.watched.where.not(board_vendor: nil).count,
      candidates: Company.tracked.resolution_candidates.count,
      unresolved: Company.tracked.where(resolution_status: [ nil, "failed" ]).count,
      proposed: Company.suggested.count # proposals waiting for the operator (4b)
    }
  end

  # The latest checks asked for from the pages, newest first.
  def recent_runs(limit = RECENT_RUNS)
    CheckRun.newest_first.limit(limit).includes(:company, :posting)
  end

  # API credit spent on LLM calls, from the record.
  def spend
    {
      total: LlmCall.sum(:cost_usd).to_f,
      last_30_days: LlmCall.where(called_at: 30.days.ago..).sum(:cost_usd).to_f,
      last_call: LlmCall.maximum(:called_at)
    }
  end
end
