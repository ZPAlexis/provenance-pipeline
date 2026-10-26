module ProvenanceMcp
  module Tools
    # Roles the client judged may fit (2f step 3), proposed as suggestions when the operator asks: as agent:assistant,
    # under a credential for this one call holding postings:suggest. Each is the client's, with its reason, and the
    # suggester never refits or withdraws it while its page lists it. Only the operator tracks or dismisses one.
    class SuggestRoles < SaveTool
      tool_name "suggest_roles"
      title "Suggest roles"
      description "Proposes roles find_roles listed, by their keys, as suggestions for the operator, each with why it may " \
                  "fit, in a sentence or two. They show among the suggested roles in the app, as yours; only the operator " \
                  "tracks or dismisses one. Read their descriptions next with read_descriptions, by the role ids returned."
      scopes "postings:suggest"
      MAX_ROLES = 20
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
        def answer(roles:)
          asked = Array(roles).map { |role| WrittenFrom.plain(role) }
          raise Refusal, "Name the roles to suggest: each by its key from find_roles, with why." if asked.empty?
          raise Refusal, "At most #{MAX_ROLES} roles a call." if asked.size > MAX_ROLES

          suggested, refused = [], []
          asked.each do |role|
            suggested << Verifier::Suggestions.propose!(role["key"], why: role["why"], actor: ASSISTANT)
          rescue ArgumentError, ActiveRecord::RecordInvalid => e
            refused << "- #{role['key']}: #{e.message}"
          end
          raise Refusal, "None suggested:\n#{refused.join("\n")}" if suggested.empty?

          ProvenanceMcp.text(
            "Suggested #{suggested.size} #{suggested.one? ? 'role' : 'roles'}, as yours, among the suggested roles in the app:",
            *suggested.map { |posting| "- #{posting.role_title} at #{posting.company.name}: role id #{posting.id}" },
            ("Not suggested:\n#{refused.join("\n")}" if refused.any?),
            "Read their descriptions next with read_descriptions: #{suggested.map(&:id).join(', ')}."
          )
        end
      end
    end
  end
end
