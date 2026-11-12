module ProvenanceMcp
  module Tools
    # A review of the resume against an application's role, saved back when the operator says so: as
    # agent:assistant, under a credential for this one call holding resume_reviews:write.
    class SaveResumeReview < SaveTool
      tool_name "save_resume_review"
      title "Save a resume review"
      description "Saves a review of the resume against an application's role that you wrote, only when the operator " \
                  "asks you to save it: strengths with the resume lines that show them, gaps, suggestions naming the " \
                  "lines they touch, and a note. Give the resume_version from get_application_materials and cite lines by number. " \
                  "A strength or suggestion drawn from the operator's background not on the resume cites its lines in " \
                  "background_lines, with the background_version: it is flagged for them to confirm."
      scopes "resume_reviews:write"

      LINES = SaveDraft::LINES
      BACKGROUND_LINES = SaveDraft::BACKGROUND_LINES
      input_schema(
        properties: {
          application: { type: "string", description: "Its id, or its company and role" },
          resume_version: { type: "string", description: "The resume's version, as get_application_materials gives it" },
          language: { type: "string", description: "The language it is written in, named in English" },
          strengths: {
            type: "array", description: "What the role asks that the resume shows, strongest first",
            items: { type: "object", properties: { point: { type: "string" }, lines: LINES, background_lines: BACKGROUND_LINES }, required: %w[point lines] }
          },
          gaps: {
            type: "array", description: "What the role asks for that the resume doesn't show",
            items: { type: "object", properties: { asks: { type: "string" }, note: { type: "string" } }, required: %w[asks note] }
          },
          suggestions: {
            type: "array", description: "Changes to the resume for this role, each naming the lines it touches",
            items: { type: "object", properties: { change: { type: "string" }, lines: LINES, background_lines: BACKGROUND_LINES }, required: %w[change lines] }
          },
          note: { type: "string", description: "How well the resume fits the role, and the one change that would help most" },
          background_version: { type: "string", description: "The background's version, as get_application_materials gives it, when you drew on it" },
          model: { type: "string", description: "The model you are, as you know it (recorded as reported)" }
        },
        required: %w[application resume_version language]
      )

      class << self
        def answer(application:, resume_version:, language:, strengths: [], gaps: [], suggestions: [], note: nil, model: nil,
                   background_version: nil)
          found = Lookup.application(application)
          review, summary = ResumeReviews.save!(found, language: language, resume_version: resume_version, strengths: strengths, gaps: gaps,
                                                       suggestions: suggestions, note: note, reported_model: model, actor: ASSISTANT,
                                                       background_version: background_version)
          ProvenanceMcp.text("Saved for #{Writing.label(found)}: #{summary}",
                             "Review id #{review.id}, on the application's page in the app (/applications/#{found.id}#reviews).")
        end
      end
    end
  end
end
