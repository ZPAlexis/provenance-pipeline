module ProvenanceMcp
  module Tools
    # A company's verdict history (the side track's R8): each change in whether its roles are still listed, read from
    # the audit log's [before, after] pairs, with LAG for the time since the same role's previous change.
    class VerificationHistory < ReadTool
      tool_name "verification_history"
      title "A company's verification history"
      description "Every change in the verdict on a company's roles, newest first: when (UTC), from what to what, which " \
                  "role, who made it (an agent, or the operator), and how long after that role's previous change. " \
                  "Verdicts: verified_live (still listed on the company's own careers page), not_found (no longer " \
                  "listed), inaccessible (couldn't confirm), pending (no answer yet). A role's first verdict reads as " \
                  "first recorded. Use it to see when and how a company's roles came and went. Finds the company by " \
                  "its exact name, case aside; says so when none or several match."
      input_schema(
        properties: { company: { type: "string", description: "The company's exact name, case aside, e.g. Acme" } },
        required: [ "company" ]
      )

      COMPANY = <<~SQL.freeze
        SELECT id, name
        FROM companies
        WHERE LOWER(name) = LOWER($1)
      SQL

      QUERY = <<~SQL.freeze
        WITH changes AS (
          SELECT c.name,
                ae.occurred_at,
                ae.actor,
                p.role_title,
                ae.changes_made -> 'verification_state' ->> 1 AS new_state,
                COALESCE(ae.changes_made -> 'verification_state' ->> 0, 'first recorded') AS prev_state,
                ae.occurred_at - LAG(ae.occurred_at)
                  OVER (PARTITION BY ae.target_id ORDER BY ae.occurred_at, ae.id) AS time_between
          FROM audit_events ae
          JOIN postings p ON ae.target_id = p.id
          AND ae.target_type = 'Posting'
          JOIN companies c ON p.company_id = c.id
          WHERE ae.changes_made ? 'verification_state'
          AND LOWER(c.name) = LOWER($1)
        )
        SELECT to_char(occurred_at, 'YYYY-MM-DD HH24:MI') AS changed_at,
          prev_state,
          new_state,
          EXTRACT(EPOCH FROM time_between) AS seconds_between,
          role_title,
          actor
        FROM changes
        ORDER BY occurred_at DESC
      SQL

      class << self
        def answer(company:)
          company = company.to_s.strip
          raise Refusal, "Name a company: its exact name." if company.empty?

          matches = ProvenanceMcp.rows(COMPANY, company)
          raise Refusal, "No company is named #{company.inspect}." if matches.empty?
          raise Refusal, "Several companies are named #{company.inspect}, so their histories would mix." if matches.size > 1

          name = matches.sole["name"]
          found = ProvenanceMcp.rows(QUERY, company)
          return ProvenanceMcp.text("No verdict changes on record for #{name}'s roles.") if found.empty?

          ProvenanceMcp.text("#{name}: #{found.size} verdict #{'change'.pluralize(found.size)} on its roles, newest first (UTC):",
                             found.map { |row| line(row) })
        end

        private

        def line(row)
          verdict = row["prev_state"] == "first recorded" ? "first recorded as #{row['new_state']}" : "#{row['prev_state']} → #{row['new_state']}"
          gap = ", #{between(row['seconds_between'].to_f)} after its previous change" if row["seconds_between"]
          "- #{row['changed_at']}: #{row['role_title']}: #{verdict}, by #{row['actor']}#{gap}"
        end

        # The gap in the unit a person would use: minutes under an hour, hours under two days, days after that.
        def between(seconds)
          return "#{(seconds / 60).round} min" if seconds < 3_600
          return "#{(seconds / 3_600).round} h" if seconds < 2 * 86_400

          "#{(seconds / 86_400).round(1)} days"
        end
      end
    end
  end
end
