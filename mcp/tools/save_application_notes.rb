module ProvenanceMcp
  module Tools
    # An application's notes and pay expectation, on the operator's word (4f step 1): a note added after what is there,
    # dated as the assistant's, never in its place (Authority refuses notes that don't begin with the ones before); the
    # pay expectation set, or replaced, when they say. As agent:assistant, under a credential for this one call holding
    # applications:note, with the operator's reason on the record. An application's stage stays theirs alone.
    class SaveApplicationNotes < SaveTool
      tool_name "save_application_notes"
      title "Add to an application's notes"
      description "Adds a note to an application's notes, or sets its pay expectation, only when the operator tells you " \
                  "to. The note goes after what is there, dated as yours, never in its place: nothing already in the " \
                  "notes is changed. The pay expectation is one value: what the operator gives replaces the one there. " \
                  "Recorded as yours, with their reason. It never moves the application between stages."
      scopes "applications:note"
      input_schema(
        properties: {
          application: { type: "string", description: "Its id, or its company and role" },
          note: { type: "string", description: "What to add to its notes, as the operator gave it or asked you to put it" },
          pay_expectation: { type: "string", description: "Its pay expectation, as the operator said it (e.g. 25k a month)" },
          reason: { type: "string", description: "The operator's reason, as they gave it: it goes on the record" }
        },
        required: %w[application reason]
      )

      class << self
        def answer(application:, reason:, note: nil, pay_expectation: nil)
          found = Lookup.application(application)
          raise Refusal, "Give the operator's reason: it goes on the record." if reason.to_s.strip.empty?
          raise Refusal, "Give a note to add, or a pay expectation." if note.to_s.strip.empty? && pay_expectation.to_s.strip.empty?

          before = found.comp_expectation
          saved = Pipeline.add_note!(found, note: note, comp_expectation: pay_expectation, reason: reason, actor: ASSISTANT)
          return ProvenanceMcp.text(Writing.fence("record", Writing.label(found)), "Nothing changed: its pay expectation is that already.") unless saved

          ProvenanceMcp.text(Writing.fence("record", Writing.label(found)),
                             ("Added to its notes, dated #{Date.current.iso8601}, after what was there." if note.to_s.strip.present?),
                             pay_line(found, before),
                             "Recorded as yours, with the operator's reason; they can edit the notes on the application's page " \
                             "(/applications/#{found.id}). Application id #{found.id}.")
        end

        private

        # The pay expectation as it now stands, and the one it replaced: the record's text, between markers.
        def pay_line(application, before)
          return if application.comp_expectation == before

          [ "Its pay expectation is set; between markers, the new one#{' and the one it replaced' if before}:",
            Writing.fence("notes", [ "Now: #{application.comp_expectation}", ("Was: #{before}" if before) ].compact.join("\n")) ]
        end
      end
    end
  end
end
