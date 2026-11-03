module ProvenanceMcp
  module Tools
    # Watched companies whose careers page hasn't been checked lately (the side track's R7): each one's latest
    # verification check, picked with ROW_NUMBER, and the ones never checked at all.
    class WatchFreshness < ReadTool
      tool_name "watch_freshness"
      title "Watch freshness"
      description "Watched companies whose latest verification check is more than `days` whole days old (UTC), or that " \
                  "have never been checked, stalest first: when each was last checked, how its page was read, and how " \
                  "many listings it found. Use it to see which companies are due a check. Says so when every watched " \
                  "company was checked within that many days."
      input_schema(
        properties: { days: { type: "integer", description: "Whole days: a company last checked more days ago than this is listed, e.g. 7" } },
        required: [ "days" ]
      )

      QUERY = <<~SQL.freeze
        WITH LatestPerGroup AS (
          SELECT
            ROW_NUMBER() OVER (PARTITION BY c.id ORDER BY pc.checked_at DESC, pc.id DESC) AS RowNumber,
            c.name,
            pc.checked_at,
            (NOW() AT TIME ZONE 'UTC')::date - pc.checked_at::date AS age,
            pc.read_via,
            pc.listing_count
          FROM companies c
          LEFT JOIN page_checks pc
          ON pc.company_id = c.id
          AND pc.purpose = 'verification'
          WHERE c.resolution_status = 'resolved'
          AND (c.kind <> 'aggregator' OR c.kind IS NULL)
        )
        SELECT
          name,
          to_char(checked_at, 'YYYY-MM-DD HH24:MI') AS last_checked,
          age,
          read_via,
          listing_count
        FROM LatestPerGroup
        WHERE RowNumber = 1
        AND (age > $1::int OR age IS NULL)
        ORDER BY LatestPerGroup.checked_at NULLS FIRST, name
      SQL

      class << self
        def answer(days:)
          raise Refusal, "Give a number of days, 1 or more." unless days.positive?

          found = ProvenanceMcp.rows(QUERY, days)
          return ProvenanceMcp.text("Every watched company was checked in the last #{days} #{'day'.pluralize(days)}.") if found.empty?

          ProvenanceMcp.text("Watched companies last checked more than #{days} #{'day'.pluralize(days)} ago, or never " \
                             "(#{found.size}), stalest first:", found.map { |row| line(row) })
        end

        private

        def line(row)
          return "- #{row['name']}: never checked" unless row["last_checked"]

          listings = row["listing_count"] ? "#{row['listing_count']} #{'listing'.pluralize(row['listing_count'])}" : "listings not counted"
          "- #{row['name']}: last checked #{row['last_checked']} UTC (#{row['age']} #{'day'.pluralize(row['age'])} ago), " \
            "read via #{row['read_via'] || 'an unrecorded method'}, #{listings}"
        end
      end
    end
  end
end
