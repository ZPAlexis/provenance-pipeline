module ProvenanceMcp
  module Tools
    # A cover letter, an outreach note, or a tailored resume the client wrote, saved back to its application when
    # the operator says so: as agent:assistant, under a credential for this one call holding drafts:write. The
    # operator edits and approves it in the app; nothing is sent.
    class SaveDraft < SaveTool
      tool_name "save_draft"
      title "Save a draft"
      description "Saves a cover letter, an outreach note, or a tailored resume you wrote for an application, only when " \
                  "the operator asks you to save it. Give the resume_version from get_application_materials and cite " \
                  "resume lines by their numbers. A polished version of a saved draft names it in `revises`: the earlier " \
                  "one stays. The operator edits and approves it in the app; nothing is sent."
      scopes "drafts:write"

      LINES = { type: "array", items: { type: "integer" }, description: "Resume lines, by their numbers" }.freeze
      input_schema(
        properties: {
          application: { type: "string", description: "Its id, or its company and role" },
          kind: { type: "string", enum: %w[cover_letter outreach_note tailored_resume] },
          resume_version: { type: "string", description: "The resume's version, as get_application_materials gives it" },
          language: { type: "string", description: "The language it is written in, named in English" },
          body: { type: "string", description: "The text: the letter, the note, or the whole tailored resume" },
          subject: { type: "string", description: "An outreach note's subject line" },
          lines_drawn_on: {
            type: "array", description: "A letter's or note's: each resume line it relies on, with what in the role it answers",
            items: { type: "object", properties: { line: { type: "integer" }, answers: { type: "string" } }, required: %w[line answers] }
          },
          changes: {
            type: "array", description: "A tailored resume's: what changed and why, naming the original lines",
            items: { type: "object", properties: { change: { type: "string" }, lines: LINES }, required: %w[change lines] }
          },
          gaps: {
            type: "array", description: "What the role asks for that the resume doesn't show",
            items: { type: "object", properties: { asks: { type: "string" }, note: { type: "string" } }, required: %w[asks note] }
          },
          note: { type: "string", description: "One or two sentences to the operator about it" },
          revises: { type: "string", description: "The id of the saved draft this one polishes, if it does" },
          model: { type: "string", description: "The model you are, as you know it (recorded as reported)" }
        },
        required: %w[application kind resume_version language body]
      )

      class << self
        def answer(application:, kind:, resume_version:, language:, body:, subject: nil, lines_drawn_on: [], changes: [], gaps: [],
                   note: nil, revises: nil, model: nil)
          found = Writing.find_application(application)
          draft, summary = Drafts.save!(found, kind: kind == "outreach_note" ? "outreach" : kind, language: language, body: body,
                                               resume_version: resume_version, subject: subject, lines_drawn_on: lines_drawn_on,
                                               changes: changes, gaps: gaps, note: note, revises: revises, reported_model: model,
                                               actor: ASSISTANT)
          ProvenanceMcp.text("Saved for #{Writing.label(found)}: #{summary}",
                             "Draft id #{draft.id}. The operator edits and approves it on the application's page in the app " \
                             "(/applications/#{found.id}#drafts); nothing is sent.")
        end
      end
    end
  end
end
