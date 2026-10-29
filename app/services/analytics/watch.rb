module Analytics
  # The watch (3.3 step 2): how long roles stay listed, how often their answers change, and how fresh the answers
  # are. From the audit log, which holds each answer given, and the page reads, which hold every role each read
  # matched, confirmed or not. Read-only.
  module Watch
    # How long roles stayed listed, in days: those since seen gone, and those listed still (so far).
    Lasting = Data.define(:closed, :closed_median, :closed_longest, :listed, :listed_median, :listed_longest)
    # One week's answers: how many roles the reads matched, how many answers changed, and to what.
    Week = Data.define(:week, :checked, :changed, :gone, :listed, :other, :by_operator)
    # The tracked roles' answers now: checked lately (within Overview::STALE_AFTER), longer ago, or never.
    Freshness = Data.define(:tracked, :fresh, :stale, :never, :oldest)
    Report = Data.define(:since, :lasting, :weeks, :freshness)

    module_function

    def report(since: nil, now: Time.current)
      Report.new(since: since, lasting: lasting(since, now.to_date), weeks: weeks(since), freshness: freshness(now))
    end

    # From the first time a role was seen listed to the first time it was seen gone after that, by the days of the
    # checks themselves (an imported answer's check date, the verifier's time of reading), not of the writes; for the
    # roles first seen listed since a day. One listed still counts its days so far.
    def lasting(since, today)
      row = Analytics.rows(<<~SQL, since, today).sole
        WITH seen AS (
          SELECT target_id AS posting_id,
                 changes_made -> 'verification_state' ->> 1 AS answer,
                 coalesce((changes_made -> 'last_checked_at' ->> 1)::timestamp, occurred_at) AS seen_at
          FROM audit_events
          WHERE target_type = 'Posting' AND action IN ('create', 'update') AND changes_made ? 'verification_state'
        ),
        first_listed AS (
          SELECT posting_id, min(seen_at) AS listed_at
          FROM seen
          WHERE answer = 'verified_live'
          GROUP BY posting_id
          HAVING $1::date IS NULL OR min(seen_at) >= $1::date
        ),
        lasted AS (
          SELECT first_listed.posting_id, first_listed.listed_at,
                 min(seen.seen_at) FILTER (WHERE seen.answer = 'not_found' AND seen.seen_at > first_listed.listed_at) AS gone_at
          FROM first_listed
          JOIN seen USING (posting_id)
          GROUP BY first_listed.posting_id, first_listed.listed_at
        ),
        days AS (
          SELECT lasted.gone_at IS NOT NULL AS closed,
                 postings.verification_state = 'verified_live' AS listed,
                 coalesce(lasted.gone_at::date, $2::date) - lasted.listed_at::date AS days
          FROM lasted
          LEFT JOIN postings ON postings.id = lasted.posting_id
        )
        SELECT count(*) FILTER (WHERE closed) AS closed,
               percentile_cont(0.5) WITHIN GROUP (ORDER BY days) FILTER (WHERE closed) AS closed_median,
               max(days) FILTER (WHERE closed) AS closed_longest,
               count(*) FILTER (WHERE NOT closed AND listed) AS listed,
               percentile_cont(0.5) WITHIN GROUP (ORDER BY days) FILTER (WHERE NOT closed AND listed) AS listed_median,
               max(days) FILTER (WHERE NOT closed AND listed) AS listed_longest
        FROM days
      SQL
      Lasting.new(**row.symbolize_keys.merge(closed_median: row["closed_median"]&.round(1), listed_median: row["listed_median"]&.round(1)))
    end

    # Week by week (weeks start on Monday, UTC), newest first: the roles the verification reads matched, and the
    # answers that changed, to gone, to listed or to another, with how many of those were the operator's own.
    def weeks(since)
      Analytics.rows(<<~SQL, since).map { |row| Week.new(**row.symbolize_keys) }
        WITH checked AS (
          SELECT date_trunc('week', checks.checked_at)::date AS week, count(*) AS checked
          FROM page_checks AS checks
          CROSS JOIN LATERAL jsonb_array_elements(checks.matches) AS matched
          WHERE checks.purpose = 'verification' AND ($1::date IS NULL OR checks.checked_at >= $1::date)
          GROUP BY 1
        ),
        changed AS (
          SELECT date_trunc('week', occurred_at)::date AS week, count(*) AS changed,
                 count(*) FILTER (WHERE changes_made -> 'verification_state' ->> 1 = 'not_found') AS gone,
                 count(*) FILTER (WHERE changes_made -> 'verification_state' ->> 1 = 'verified_live') AS listed,
                 count(*) FILTER (WHERE changes_made -> 'verification_state' ->> 1 NOT IN ('not_found', 'verified_live')) AS other,
                 count(*) FILTER (WHERE actor LIKE 'human:%') AS by_operator
          FROM audit_events
          WHERE target_type = 'Posting' AND action = 'update' AND changes_made ? 'verification_state'
            AND ($1::date IS NULL OR occurred_at >= $1::date)
          GROUP BY 1
        )
        SELECT week, coalesce(checked, 0) AS checked, coalesce(changed, 0) AS changed, coalesce(gone, 0) AS gone,
               coalesce(listed, 0) AS listed, coalesce(other, 0) AS other, coalesce(by_operator, 0) AS by_operator
        FROM checked
        FULL OUTER JOIN changed USING (week)
        ORDER BY week DESC
      SQL
    end

    def freshness(now)
      row = Analytics.rows(<<~SQL, now - Overview::STALE_AFTER, now.to_date).sole
        SELECT count(*) AS tracked,
               count(*) FILTER (WHERE last_checked_at >= $1::timestamp) AS fresh,
               count(*) FILTER (WHERE last_checked_at < $1::timestamp) AS stale,
               count(*) FILTER (WHERE last_checked_at IS NULL) AS never,
               max($2::date - last_checked_at::date) AS oldest
        FROM postings
        WHERE tracking = 'tracked'
      SQL
      Freshness.new(**row.symbolize_keys)
    end

    private_class_method :lasting, :weeks, :freshness
  end
end
