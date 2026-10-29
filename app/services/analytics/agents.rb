module Analytics
  # The agents (3.3 step 2): what the AI cost, by day, purpose and model, and per role the reads confirmed listed;
  # how the review queue's recommendations came out; and what each actor wrote and was refused. From the LLM calls,
  # the page reads, the review items and the audit log. Read-only.
  module Agents
    # One day's AI calls, their cost, and the running total from the period's start.
    Day = Data.define(:day, :calls, :cost, :running)
    # The calls of one purpose on one model, and their share of the period's cost.
    Spend = Data.define(:purpose, :model, :calls, :tokens_in, :tokens_out, :cost, :share)
    # The verification reads: how many, how many needed the AI, what that cost, and the roles they confirmed listed.
    # A read through a board's API needs no AI and still counts, so the cost a read is never overstated.
    Reads = Data.define(:reads, :with_ai, :cost, :confirmed) do
      def per_read = (cost / reads if reads.positive?)

      def per_confirmed = (cost / confirmed if confirmed.positive?)
    end
    # One kind's recommendations: agreed, differed, resolved on their own, and pending; agreement of those decided.
    Agreement = Data.define(:kind, :agreed, :differed, :resolved, :pending) do
      def decided = agreed + differed

      def rate = ((100.0 * agreed / decided).round if decided >= FLOOR)
    end
    # What one actor wrote and was refused, and the credentials its runs were issued (none for the operator).
    Actor = Data.define(:actor, :writes, :refused, :credentials)
    Report = Data.define(:since, :days, :spend, :reads, :agreement, :actors) do
      def cost = spend.sum(&:cost)
    end

    module_function

    def report(since: nil)
      Report.new(since: since, days: days(since), spend: spend(since), reads: reads(since), agreement: agreement(since),
                 actors: actors(since))
    end

    def days(since)
      Analytics.rows(<<~SQL, since).map { |row| Day.new(**row.symbolize_keys) }
        SELECT called_at::date AS day, count(*) AS calls, sum(cost_usd)::float8 AS cost,
               (sum(sum(cost_usd)) OVER (ORDER BY called_at::date))::float8 AS running
        FROM llm_calls
        WHERE $1::date IS NULL OR called_at >= $1::date
        GROUP BY called_at::date
        ORDER BY day
      SQL
    end

    def spend(since)
      Analytics.rows(<<~SQL, since).map { |row| Spend.new(**row.symbolize_keys) }
        SELECT purpose, model, count(*) AS calls, sum(input_tokens) AS tokens_in, sum(output_tokens) AS tokens_out,
               sum(cost_usd)::float8 AS cost,
               (sum(cost_usd) / nullif(sum(sum(cost_usd)) OVER (), 0))::float8 AS share
        FROM llm_calls
        WHERE $1::date IS NULL OR called_at >= $1::date
        GROUP BY purpose, model
        ORDER BY cost DESC, purpose, model
      SQL
    end

    # Every verification read, joined to the AI calls it needed, if any (a left join, or the reads that needed none
    # would drop out and the cost a read rise); the roles confirmed listed are those any of the reads matched as listed.
    def reads(since)
      row = Analytics.rows(<<~SQL, since).sole
        WITH reads AS (
          SELECT id, matches
          FROM page_checks
          WHERE purpose = 'verification' AND ($1::date IS NULL OR checked_at >= $1::date)
        ),
        costed AS (
          SELECT reads.id, count(calls.id) AS calls, coalesce(sum(calls.cost_usd), 0) AS cost
          FROM reads
          LEFT JOIN llm_calls AS calls ON calls.page_check_id = reads.id
          GROUP BY reads.id
        ),
        confirmed AS (
          SELECT DISTINCT matched ->> 'posting_id' AS posting_id
          FROM reads
          CROSS JOIN LATERAL jsonb_array_elements(reads.matches) AS matched
          WHERE matched ->> 'verdict' = 'verified_live'
        )
        SELECT (SELECT count(*) FROM costed) AS reads,
               (SELECT count(*) FROM costed WHERE calls > 0) AS with_ai,
               (SELECT coalesce(sum(cost), 0) FROM costed)::float8 AS cost,
               (SELECT count(*) FROM confirmed) AS confirmed
      SQL
      Reads.new(**row.symbolize_keys)
    end

    # The review queue's recommendations made since a day (2g's measure), by kind.
    def agreement(since)
      items = ReviewItem.recommended
      items = items.where("(review_items.recommendation ->> 'at')::timestamp >= ?", since.beginning_of_day) if since
      ReviewRecommendations.agreement(items).sort_by { |kind, _| ReviewItem::KINDS.index(kind) }.map do |kind, tally|
        Agreement.new(kind, *ReviewRecommendations::OUTCOMES.map { |outcome| tally.fetch(outcome, 0) })
      end
    end

    # Writes and refusals by actor (every human as the operator), beside the credentials issued to each agent.
    def actors(since)
      Analytics.rows(<<~SQL, since).map { |row| Actor.new(**row.symbolize_keys) }
        WITH written AS (
          SELECT CASE WHEN actor LIKE 'human:%' THEN 'operator' ELSE actor END AS actor,
                 count(*) FILTER (WHERE action <> 'denied') AS writes,
                 count(*) FILTER (WHERE action = 'denied') AS refused
          FROM audit_events
          WHERE $1::date IS NULL OR occurred_at >= $1::date
          GROUP BY 1
        ),
        issued AS (
          SELECT actor, count(*) AS credentials
          FROM agent_credentials
          WHERE $1::date IS NULL OR created_at >= $1::date
          GROUP BY actor
        )
        SELECT actor, coalesce(writes, 0) AS writes, coalesce(refused, 0) AS refused, coalesce(credentials, 0) AS credentials
        FROM written
        FULL OUTER JOIN issued USING (actor)
        ORDER BY writes DESC, actor
      SQL
    end

    private_class_method :days, :spend, :reads, :agreement, :actors
  end
end
