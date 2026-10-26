module ProvenanceMcp
  module Tools
    # Roles' descriptions read from their own pages (2f step 3), so their fit can be weighed: by the verifier, under its
    # own credential, as the role page's "Read its description" does. Free: a board's job API, or the page rendered;
    # never the LLM. Nothing is written as the client.
    class ReadDescriptions < RunTool
      tool_name "read_descriptions"
      title "Read roles' descriptions"
      description "Reads the descriptions of roles on record (tracked ones, say) from their own pages, by role id, so they " \
                  "can be weighed: free, through a board's job API or the page rendered, never an AI. The app's verifier " \
                  "reads them, as the role page's button does. suggest_roles reads its suggestions' own. A few seconds a " \
                  "role; up to 10 a call."
      MAX_ROLES = 10
      input_schema(
        properties: { roles: { type: "array", items: { type: "string" }, description: "Up to #{MAX_ROLES} role ids" } },
        required: [ "roles" ]
      )

      class << self
        def answer(roles:)
          ids = Array(roles).map { |id| id.to_s.strip }.select { |id| id.match?(Lookup::UUID) }.uniq
          raise Refusal, "At most #{MAX_ROLES} roles a call." if ids.size > MAX_ROLES

          postings = Posting.includes(:company).where(id: ids).to_a
          raise Refusal, "No role by those ids: find_roles and suggest_roles give them, or get_roles_to_weigh." if postings.empty?

          reads = Verifier::Descriptions.read!(postings, purpose: "mcp: read_descriptions")
          ProvenanceMcp.text(
            "Read #{reads.count { |read| read.outcome == 'ok' }} of #{reads.size}:",
            *reads.map { |read| "- #{read.posting.role_title} at #{read.posting.company.name} (#{read.posting.id}): #{read.summary}" },
            "Weigh the ones read with get_roles_to_weigh."
          )
        end
      end
    end
  end
end
