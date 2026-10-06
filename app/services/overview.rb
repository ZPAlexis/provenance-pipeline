# What the dashboard shows: where the tracked roles stand, what changed lately,
# the companies watched, and what reading pages has cost. Read-only.
module Overview
  RECENT_CHANGES = 12
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

  def stale_count
    Posting.tracked.where(last_checked_at: ...STALE_AFTER.ago).count
  end

  # The latest verdicts that changed, newest first: the verifier's and the operator's.
  def recent_changes(limit = RECENT_CHANGES)
    AuditEvent.where(target_type: "Posting", action: "update").where("changes_made ? 'verification_state'")
              .order(occurred_at: :desc).limit(limit).preload(target: :company)
  end

  def companies
    {
      watched: Company.where(resolution_status: "resolved").count,
      boards: Company.where.not(board_vendor: nil).count,
      candidates: Company.resolution_candidates.count,
      unresolved: Company.where(resolution_status: [ nil, "failed" ]).count
    }
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
