module ProvenanceMcp
  module Tools
    # The writing rules for one kind of writing, as the prompts give them: for a client asked to write without one.
    class WritingRules < ReadTool
      tool_name "get_writing_rules"
      title "The writing rules"
      description "The rules for writing a cover letter, an outreach note, a resume review or a tailored resume about " \
                  "an application, and the shape of the answer: the same rules the in-app drafter keeps. Read them " \
                  "before writing from get_application_materials, and keep them through every change."
      input_schema(
        properties: {
          kind: { type: "string", enum: Writing::KINDS.keys, description: "What to write" },
          language: { type: "string", description: "Optional: the language to write in" }
        },
        required: [ "kind" ]
      )

      class << self
        def answer(kind:, language: nil) = ProvenanceMcp.text(Writing.instructions(kind, language: language))
      end
    end
  end
end
