module ProvenanceMcp
  module Tools
    # Roles the client judged may fit (2f step 3), proposed as suggestions when the operator asks. Each role's own page
    # is read first (free, never the LLM, keeping nothing), since find_roles lists the pages as last read: a role whose
    # page is gone, or can't be read, isn't suggested. The rest become suggestions as agent:assistant, under a
    # credential for this call holding postings:suggest, and the descriptions just read are kept by the verifier under
    # its own, so they are ready to weigh. Only the operator tracks or dismisses one.
    class SuggestRoles < SaveTool
      tool_name "suggest_roles"
      title "Suggest roles"
      MAX_ROLES = 10
      description "Proposes roles find_roles listed, by their keys, as suggestions for the operator, each with why it may " \
                  "fit, in a sentence or two. Each role's own page is read first (free): one whose page is gone or can't " \
                  "be read isn't suggested, and the rest are suggested with their descriptions read, ready for " \
                  "get_roles_to_weigh. They show among the suggested roles in the app, as yours; only the operator tracks " \
                  "or dismisses one. Up to #{MAX_ROLES} a call: a few seconds a role."
      scopes "postings:suggest"
      input_schema(
        properties: {
          roles: {
            type: "array", description: "Up to #{MAX_ROLES} roles, each by its key from find_roles, with why it may fit",
            items: { type: "object", properties: { key: { type: "string" }, why: { type: "string" } }, required: %w[key why] }
          }
        },
        required: [ "roles" ]
      )

      class << self
        # The pages are read before any credential is issued (nothing is written by the read); then the suggestions,
        # as the assistant; then the descriptions, as the verifier.
        def call(server_context: nil, **arguments)
          ProvenanceMcp.ready!
          guarded { answer(**arguments) }
        end

        def answer(roles:)
          asked = Array(roles).map { |role| WrittenFrom.plain(role) }
          raise Refusal, "Name the roles to suggest: each by its key from find_roles, with why." if asked.empty?
          raise Refusal, "At most #{MAX_ROLES} roles a call." if asked.size > MAX_ROLES

          candidates, refused = found(asked)
          peeked = Verifier::Descriptions.peek(candidates.map { |candidate, _| { id: candidate.key, url: candidate.url, label: candidate.label } })
          up = candidates.select { |candidate, _| peeked.results.dig(candidate.key, "outcome") == "ok" }
          (candidates - up).each do |candidate, _|
            result = peeked.results.fetch(candidate.key)
            gone = " Its company's next check takes it off the list." if result["outcome"] == "gone"
            refused << "- #{candidate.listing['title']} at #{candidate.company.name}: #{Verifier::Descriptions.why_not(result)}#{gone}"
          end
          raise Refusal, "None suggested:\n#{refused.join("\n")}" if up.empty?

          suggested = as_assistant { up.map { |candidate, why| [ Verifier::Suggestions.propose!(candidate, why: why, actor: ASSISTANT), candidate ] } }
          reads = Verifier::Descriptions.keep!(suggested.map { |posting, candidate| [ posting, peeked.results.fetch(candidate.key) ] },
                                               run_id: peeked.run_id, purpose: "mcp: suggest_roles, the descriptions read")
          ProvenanceMcp.text(
            "Read #{candidates.size} #{candidates.one? ? "role's own page" : "roles' own pages"} first (free): suggested " \
            "#{suggested.size} still up, as yours, among the suggested roles in the app, each with its description read:",
            *suggested.zip(reads).map { |(posting, _), read| "- #{posting.role_title} at #{posting.company.name}: role id #{posting.id} (#{read.summary.downcase_first})" },
            ("Not suggested:\n#{refused.join("\n")}" if refused.any?),
            "Weigh them next with get_roles_to_weigh: #{suggested.map { |posting, _| posting.id }.join(', ')}."
          )
        end

        private

        # The roles asked for that can be suggested, each with why; and why the others can't.
        def found(asked)
          refused = []
          candidates = asked.uniq { |role| role["key"] }.filter_map do |role|
            candidate = Verifier::Suggestions.candidate!(role["key"])
            unless candidate.url
              refused << "- #{candidate.listing['title']} at #{candidate.company.name}: no page of its own to read, nor to weigh from"
              next
            end

            [ candidate, Verifier::Suggestions.reason!(role["why"]) ]
          rescue ArgumentError => e
            refused << "- #{role['key']}: #{e.message}"
            nil
          end
          [ candidates, refused ]
        end
      end
    end
  end
end
