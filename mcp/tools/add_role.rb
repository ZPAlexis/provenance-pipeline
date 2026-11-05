module ProvenanceMcp
  module Tools
    # A role added to a company on record on the operator's word (4a step 4): tracked, and never checked here. As
    # agent:assistant, under a credential for this one call holding watchlist:curate, through the same service as the
    # app's "Add a role here", with the operator's reason on the record.
    class AddRole < SaveTool
      tool_name "add_role"
      title "Add a role"
      description "Adds a role to a company on record, tracked, only when the operator tells you to: its own page at " \
                  "the employer (or its ATS posting; never a job board's link, which is where it was found), its title, " \
                  "and its location and where it was found when known. Nothing reads it here, so nothing is spent: its " \
                  "answer stays \"no answer yet\" until the next check of its company's careers page, or the operator " \
                  "checks it in the app. A role on record with that link, or found at the same LinkedIn job, is tracked " \
                  "instead of added twice. Not at an archived company. Recorded as yours, with the reason."
      scopes "watchlist:curate"
      input_schema(
        properties: {
          company: { type: "string", description: "The company on record: its id, name, domain, or a link on its site" },
          link: { type: "string", description: "The role's own page at the employer, or its ATS posting" },
          title: { type: "string", description: "Its title, as the posting gives it" },
          location: { type: "string" },
          found_at: { type: "string", description: "Where the operator found it, a LinkedIn job say: kept, never read" },
          reason: { type: "string", description: "The operator's reason, as they gave it: it goes on the record" }
        },
        required: %w[company link title reason]
      )

      class << self
        def answer(company:, link:, title:, reason:, location: nil, found_at: nil)
          at = Lookup.company(company)
          raise Refusal, "Give its title: nothing reads it from its page here." if title.to_s.strip.empty?
          raise Refusal, "Give the operator's reason: it goes on the record." if reason.to_s.strip.empty?

          placed = Verifier::Capture.role!(link: link, title: title, location: location, source: found_at, company: at, check: false,
                                           note: reason, actor: ASSISTANT)
          role = placed.posting
          ProvenanceMcp.text(Writing.fence("record", placed.note),
                             "Role id #{role.id}, at #{at.name}: tracked, its answer #{Posting::ANSWER_LABELS.fetch(role.verification_state).downcase}" \
                             "#{', never checked here' if role.verification_state == 'pending'}. Its page in the app: /roles/#{role.id}.")
        end
      end
    end
  end
end
