# How the search is going (3.3), worked out from the record, never a copy of it: hand-written SQL over the audit
# log and the tables it describes, every input a bound parameter. Read-only. Step 1 is the pipeline: how far
# applications get, how long they sit in each stage, how they end, and what is open now.
module Analytics
  # Below this many, a rate says nothing: the page says there is too little to measure.
  FLOOR = 5
  # The stages an application goes through, in order. An accepted offer passed through Offer; closing as rejected,
  # withdrawn or no response reaches nothing further.
  FUNNEL = (Application::OPEN + %w[accepted]).freeze

  # How many applications reached a stage, and how many reached the one before it (nil for the first).
  Step = Data.define(:stage, :reached, :before) do
    def measurable? = before.to_i >= FLOOR

    def rate
      (100.0 * reached / before).round if measurable?
    end
  end
  # How long applications sat in a stage, in days: how many times one was there, how many are there still (counted
  # so far), the median and the longest.
  Stay = Data.define(:stage, :times, :still, :median, :longest)
  # How applications end: of those closed, how many were accepted; of those that got as far as applying, how many
  # reached an offer.
  Outcome = Data.define(:closed, :accepted, :applied, :offers) do
    def accepted_rate
      (100.0 * accepted / closed).round if closed >= FLOOR
    end

    def offer_rate
      (100.0 * offers / applied).round if applied >= FLOOR
    end
  end
  # The open applications at a stage now, and how long they have sat there, in days.
  Open = Data.define(:stage, :applications, :median, :longest)
  Report = Data.define(:since, :applications, :steps, :stays, :outcome, :open, :unapplied)

  # Every application's stages from its audit events, each with the day it began, as the operator dated it.
  # Only what changed is audited, so a move made the same day as the stage before carries no date, and a stage
  # re-dated in place carries a date and no stage: each event joins the stage last moved to (span), the last date
  # given while a stage was current is its own, and a stage with none takes the one before it, carried forward.
  STAGES = <<~SQL.freeze
    WITH events AS (
      SELECT target_id AS application_id, occurred_at, id,
             changes_made -> 'stage' ->> 1 AS stage,
             (changes_made -> 'stage_changed_on' ->> 1)::date AS dated
      FROM audit_events
      WHERE target_type = 'Application' AND action IN ('create', 'update')
        AND changes_made ?| array['stage', 'stage_changed_on']
    ),
    numbered AS (
      SELECT *, count(stage) OVER (PARTITION BY application_id ORDER BY occurred_at, id) AS span
      FROM events
    ),
    spans AS (
      SELECT application_id, span,
             (array_agg(stage) FILTER (WHERE stage IS NOT NULL))[1] AS stage,
             (array_agg(dated ORDER BY occurred_at DESC, id DESC) FILTER (WHERE dated IS NOT NULL))[1] AS dated,
             min(occurred_at) AS at
      FROM numbered
      WHERE span > 0
      GROUP BY application_id, span
    ),
    carried AS (
      SELECT *, count(dated) OVER (PARTITION BY application_id ORDER BY span) AS run
      FROM spans
    ),
    stages AS (
      SELECT application_id, span, stage,
             coalesce(max(dated) OVER (PARTITION BY application_id, run), at::date) AS began
      FROM carried
    ),
    cohort AS (
      SELECT application_id, min(began) AS started,
             max(coalesce(funnel.rank, 0)) AS furthest,
             (array_agg(stage ORDER BY span DESC))[1] AS now
      FROM stages
      LEFT JOIN unnest($1::text[]) WITH ORDINALITY AS funnel (stage, rank) USING (stage)
      GROUP BY application_id
      HAVING $2::date IS NULL OR min(began) >= $2::date
    )
  SQL

  module_function

  # The pipeline, for the applications started since a day (all of them when nil); what is open is as of today.
  def pipeline(since: nil, today: Date.current)
    Report.new(since: since, applications: rows("#{STAGES} SELECT count(*) AS n FROM cohort", *staged(since)).sole["n"],
                 steps: steps(since), stays: stays(since, today), outcome: outcome(since), open: open(today),
                 unapplied: unapplied)
  end

  # How many reached each stage, and the stage before's count beside it (LAG), for the rate from one to the next.
  def steps(since)
    rows(<<~SQL, *staged(since)).map { |row| Step.new(row["stage"], row["reached"], row["before"]) }
      #{STAGES}
      SELECT funnel.stage, funnel.rank, count(cohort.application_id) AS reached,
             lag(count(cohort.application_id)) OVER (ORDER BY funnel.rank) AS before
      FROM unnest($1::text[]) WITH ORDINALITY AS funnel (stage, rank)
      LEFT JOIN cohort ON cohort.furthest >= funnel.rank
      GROUP BY funnel.stage, funnel.rank
      ORDER BY funnel.rank
    SQL
  end

  # Days in each open stage: to the day the next stage began, or to today for an application still there. A
  # closed stage ends the application, and a date given out of order counts as no days.
  def stays(since, today)
    rows(<<~SQL, *staged(since), today, PG::TextEncoder::Array.new.encode(Application::OPEN)).map { |row| stay(row) }
      #{STAGES},
      ended AS (
        SELECT stages.stage, stages.began,
               lead(stages.began) OVER (PARTITION BY stages.application_id ORDER BY stages.span) AS ended
        FROM stages JOIN cohort USING (application_id)
      ),
      days AS (
        SELECT stage, ended IS NULL AS still, greatest(coalesce(ended, $3::date) - began, 0) AS days
        FROM ended
        WHERE stage = ANY($4::text[])
      )
      SELECT stage, count(*) AS times, count(*) FILTER (WHERE still) AS still,
             percentile_cont(0.5) WITHIN GROUP (ORDER BY days) AS median, max(days) AS longest
      FROM days
      JOIN unnest($1::text[]) WITH ORDINALITY AS funnel (stage, rank) USING (stage)
      GROUP BY stage, funnel.rank
      ORDER BY funnel.rank
    SQL
  end

  def outcome(since)
    ranks = [ FUNNEL.index("applied") + 1, FUNNEL.index("offer") + 1 ]
    row = rows(<<~SQL, *staged(since), PG::TextEncoder::Array.new.encode(Application::CLOSED), *ranks).sole
      #{STAGES}
      SELECT count(*) FILTER (WHERE now = ANY($3::text[])) AS closed,
             count(*) FILTER (WHERE now = 'accepted') AS accepted,
             count(*) FILTER (WHERE furthest >= $4::int) AS applied,
             count(*) FILTER (WHERE furthest >= $5::int) AS offers
      FROM cohort
    SQL
    Outcome.new(*row.values_at("closed", "accepted", "applied", "offers"))
  end

  # The open applications now, by stage, from the applications themselves.
  def open(today)
    rows(<<~SQL, today, PG::TextEncoder::Array.new.encode(Application::OPEN)).map { |row| open_stage(row) }
      SELECT stage, count(*) AS applications,
             percentile_cont(0.5) WITHIN GROUP (ORDER BY $1::date - stage_changed_on) AS median,
             max($1::date - stage_changed_on) AS longest
      FROM applications
      JOIN unnest($2::text[]) WITH ORDINALITY AS ordered (stage, rank) USING (stage)
      GROUP BY stage, ordered.rank
      ORDER BY ordered.rank
    SQL
  end

  # The tracked roles still listed that have no application: what could be applied to.
  def unapplied
    rows(<<~SQL).sole["n"]
      SELECT count(*) AS n
      FROM postings
      WHERE tracking = 'tracked' AND verification_state = 'verified_live'
        AND NOT EXISTS (SELECT 1 FROM applications WHERE applications.posting_id = postings.id)
    SQL
  end

  def staged(since) = [ PG::TextEncoder::Array.new.encode(FUNNEL), since ]

  def stay(row) = Stay.new(row["stage"], row["times"], row["still"], row["median"]&.round(1), row["longest"])

  def open_stage(row) = Open.new(row["stage"], row["applications"], row["median"]&.round(1), row["longest"])

  def rows(sql, *binds) = ApplicationRecord.connection.select_all(sql, "Analytics", binds).to_a

  private_class_method :steps, :stays, :outcome, :open, :unapplied, :staged, :stay, :open_stage, :rows
end
