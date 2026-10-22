module ProvenanceMcp
  module Tools
    # One draft in full, to polish: its text as it stands, and what it rests on.
    class GetDraft < ReadTool
      tool_name "get_draft"
      title "A draft"
      description "One cover letter or outreach note in full, by its draft id (get_application_materials lists them): " \
                  "its text as it stands, whether it is approved or edited, who wrote it, the resume lines it drew on, " \
                  "its gaps and note, and whether the resume or the role's description has changed since."
      input_schema(properties: { draft: { type: "string", description: "The draft's id" } }, required: [ "draft" ])

      class << self
        def answer(draft:)
          found = Draft.includes(:llm_call, application: %i[company posting]).find_by(id: draft.to_s.strip) # nil for a malformed id
          raise Refusal, "No draft #{draft.inspect}: get_application_materials lists an application's drafts with their ids." unless found

          ProvenanceMcp.text(about(found), ("Subject: #{found.subject}" if found.subject), "<draft>\n#{found.body}\n</draft>",
                             rests_on(found), changed_since(found))
        end

        private

        def about(draft)
          written_by = AuditEvent.where(target: draft, action: "create").pick(:actor)
          by = { "agent:drafter" => "the in-app drafter", "agent:assistant" => "your Claude client, through MCP" }.fetch(written_by, written_by || "unknown")
          "#{draft.label} for #{Writing.label(draft.application)}, in #{draft.language}: " \
            "#{draft.approved? ? "approved #{draft.approved_at.utc.to_date}" : 'a draft'}#{', edited by the operator' if draft.edited?}. " \
            "Written #{draft.created_at.utc.to_date} by #{by}#{" (#{draft.llm_call.model})" if draft.llm_call}." \
            "#{" Asked to stress: #{draft.guidance}" if draft.guidance.present?}"
        end

        def rests_on(draft)
          lines = draft.drew_on.map { |point| "- [#{point['line']}] #{point['text']} (#{point['used_for']})" }
          gaps = draft.gaps.map { |gap| "- #{gap['asks']}: #{gap['note']}" }
          [ "Lines drawn on:", *(lines.presence || [ "- none" ]), "Gaps:", *(gaps.presence || [ "- none found" ]),
            ("Note: #{draft.notes}" if draft.notes) ].compact.join("\n")
        end

        def changed_since(draft)
          resume = SearchProfile.current&.resumes&.newest_first&.first
          description = draft.application.posting.role_descriptions.newest_first.first
          changed = [ ("the resume" if resume && resume.content_hash != draft.resume_hash),
                      ("the role's description" if description && description.content_hash != draft.description_hash) ].compact
          changed.any? ? "Changed since it was written: #{changed.to_sentence}." : "The resume and the description are as they were when it was written."
        end
      end
    end
  end
end
