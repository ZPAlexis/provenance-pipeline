module ProvenanceMcp
  module Tools
    # How the search is going (3.3 step 3), worked out from the record as the Analytics page has it: the pipeline,
    # the watch and the agents, a section or all of them, for a period. Figures only, never a record's own text.
    class AnalyticsReport < ReadTool
      tool_name "get_analytics"
      title "How the search is going"
      description "How the job search is going, worked out from the record: the pipeline (how far applications get " \
                  "and the rate from one stage to the next, days in each stage, how they end, what is open now), the " \
                  "watch (how long roles stay listed, answers changed week by week, how fresh the tracked roles' " \
                  "answers are) and the agents (AI cost by purpose, model and day, the cost of reading the watched " \
                  "pages, agreement with the operator on the review queue, each one's writes and refusals). A rate needs " \
                  "at least 5 to go on: below that it says so, and so should you. Times are UTC."
      input_schema(
        properties: {
          section: { type: "string", enum: %w[pipeline watch agents], description: "One section; all three when left out" },
          since: { type: "string", description: "A day, as YYYY-MM-DD: applications started, roles first seen listed, and " \
                                                 "reads, calls and writes made since then. Everything when left out" }
        }
      )

      class << self
        def answer(section: nil, since: nil)
          day = Date.iso8601(since) if since.present?
          ProvenanceMcp.text(::Analytics::Text.report(section ? [ section ] : ::Analytics::Text::SECTIONS, since: day))
        rescue Date::Error
          raise Refusal, "Since is a day as YYYY-MM-DD, not #{since.inspect}."
        end
      end
    end
  end
end
