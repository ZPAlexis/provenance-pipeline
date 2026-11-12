module ProvenanceMcp
  module Tools
    # A role's fit as the client weighed it (2f step 3), saved when the operator asks: as agent:assistant, under a
    # credential for this one call holding fit:write, read against the resume version the client saw and the role's
    # newest description. Since 4c it is read two ways: the ATS fit (the resume alone, shown in the tables) and, read
    # against the background version the client saw, the Background fit beside it. It shows on the role's page and in the
    # Roles page's ATS fit column; nothing tracks the role.
    class SaveFitScore < SaveTool
      tool_name "save_fit_score"
      title "Save a fit score"
      description "Saves how well one role fits, as you weighed it by the rules from get_roles_to_weigh, read two ways. " \
                  "The ATS fit, from the resume alone: the score from 0 to 100, the level, the matches with the resume lines " \
                  "by their numbers, the gaps, and why. When a background is saved, the Background fit too: its version, " \
                  "score and why, the gaps the background covers (with its lines and where to address each), and the role " \
                  "preferences the role touches (a match or a miss each). Give the versions from get_roles_to_weigh. It never " \
                  "tracks the role."
      scopes "fit:write"
      LINES = { type: "array", items: { type: "string" }, description: "Background lines, as B4 (or 4)" }.freeze
      input_schema(
        properties: {
          role: { type: "string", description: "The role's id" },
          resume_version: { type: "string", description: "The resume's version, as get_roles_to_weigh gives it" },
          score: { type: "integer", description: "The ATS fit: from 0 to 100, by the fit rules' scale, from the resume alone" },
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
          why: { type: "string", description: "The one sentence that explains the ATS fit" },
          background_version: { type: "string", description: "The background's version, as get_roles_to_weigh gives it (the Background fit)" },
          background_score: { type: "integer", description: "The Background fit: from 0 to 100, from the resume and the background" },
          background_why: { type: "string", description: "The one sentence that explains the Background fit beside the ATS fit" },
          covered: {
            type: "array", description: "Gaps of the ATS reading the background covers",
            items: { type: "object", properties: { asks: { type: "string" }, lines: LINES,
                                                   address_in: { type: "string", enum: %w[resume cover_letter both] },
                                                   note: { type: "string", description: "How to address it" } },
                     required: %w[asks lines address_in] }
          },
          preferences: {
            type: "array", description: "The role preferences the role touches",
            items: { type: "object", properties: { preference: { type: "string" }, verdict: { type: "string", enum: %w[match miss] },
                                                   why: { type: "string" }, lines: LINES }, required: %w[preference verdict] }
          },
          model: { type: "string", description: "The model you are, as you know it (recorded as reported)" }
        },
        required: %w[role resume_version score why]
      )

      class << self
        def answer(role:, resume_version:, score:, why:, level: nil, matches: [], gaps: [], model: nil, background_version: nil,
                   background_score: nil, background_why: nil, covered: [], preferences: [])
          posting = Posting.includes(:company).find_by(id: role.to_s.strip) if role.to_s.strip.match?(Lookup::UUID)
          raise Refusal, "No role #{role.inspect}: get_roles_to_weigh gives each one's id." unless posting

          background = { version: background_version, score: background_score, why: background_why, covered: covered, preferences: preferences }
          background = nil if background_version.blank? && background_score.nil? && background_why.blank?
          saved, summary = FitScores.save!(posting, score: score, why: why, resume_version: resume_version, level: level, matches: matches,
                                                    gaps: gaps, reported_model: model, actor: ASSISTANT, background: background)
          ProvenanceMcp.text("Saved: #{summary}",
                             "It shows on the role's page in the app (/roles/#{posting.id}#fit) and in the Roles page's ATS fit " \
                             "column (score id #{saved.id}). It tracks nothing: the operator tracks or archives the role, or asks you to.")
        end
      end
    end
  end
end
