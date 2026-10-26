module ProvenanceMcp
  module Tools
    # A role's fit as the client weighed it (2f step 3), saved when the operator asks: as agent:assistant, under a
    # credential for this one call holding fit:write, read against the resume version the client saw and the role's
    # newest description. It shows on the role's page and in the Roles page's Fit column; nothing tracks the role.
    class SaveFitScore < SaveTool
      tool_name "save_fit_score"
      title "Save a fit score"
      description "Saves how well one role fits the resume, as you weighed it by the fit rules from get_roles_to_weigh: " \
                  "the score from 0 to 100, the level, the matches with the resume lines by their numbers, the gaps, " \
                  "and why. Give the resume version from get_roles_to_weigh. It never tracks the role."
      scopes "fit:write"
      input_schema(
        properties: {
          role: { type: "string", description: "The role's id" },
          resume_version: { type: "string", description: "The resume's version, as get_roles_to_weigh gives it" },
          score: { type: "integer", description: "From 0 to 100, by the fit rules' scale" },
          level: { type: "string", description: "The level the role asks, beside the resume's, in a few words" },
          matches: {
            type: "array", description: "The strongest things the role asks that the resume shows",
            items: { type: "object", properties: { point: { type: "string" }, lines: { type: "array", items: { type: "integer" } } },
                     required: %w[point lines] }
          },
          gaps: {
            type: "array", description: "What the role asks for that the resume doesn't show, its must-haves first",
            items: { type: "object", properties: { asks: { type: "string" }, note: { type: "string" } }, required: %w[asks note] }
          },
          why: { type: "string", description: "The one sentence that explains the score" },
          model: { type: "string", description: "The model you are, as you know it (recorded as reported)" }
        },
        required: %w[role resume_version score why]
      )

      class << self
        def answer(role:, resume_version:, score:, why:, level: nil, matches: [], gaps: [], model: nil)
          posting = Posting.includes(:company).find_by(id: role.to_s.strip) if role.to_s.strip.match?(Lookup::UUID)
          raise Refusal, "No role #{role.inspect}: get_roles_to_weigh gives each one's id." unless posting

          saved, summary = FitScores.save!(posting, score: score, why: why, resume_version: resume_version, level: level, matches: matches,
                                                    gaps: gaps, reported_model: model, actor: ASSISTANT)
          ProvenanceMcp.text("Saved: #{summary}",
                             "It shows on the role's page in the app (/roles/#{posting.id}#fit) and in the Roles page's Fit column " \
                             "(score id #{saved.id}). Only the operator tracks or dismisses the role.")
        end
      end
    end
  end
end
