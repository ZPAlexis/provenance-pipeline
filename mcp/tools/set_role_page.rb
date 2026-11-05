module ProvenanceMcp
  module Tools
    # A role's own page changed on the operator's word (4a step 4): the link each check tries first. As
    # agent:assistant, under a credential for this one call holding watchlist:curate, through the same service as the
    # role page's "Change its own page", with the operator's reason on the record.
    class SetRolePage < SaveTool
      tool_name "set_role_page"
      title "Set a role's own page"
      description "Changes a role's own page at the employer, only when the operator tells you to: the link each check " \
                  "of its company's careers page tries first to find it. The employer's page for the role, or its ATS " \
                  "posting; never a job board's link (that is where it was found), a link on another company's site, " \
                  "or another role's page. Its company's careers page is not this: the operator sets that in the app. " \
                  "Recorded as yours, with the reason."
      scopes "watchlist:curate"
      input_schema(
        properties: {
          role: { type: "string", description: "The role: its id (from get_company_status), or its company and title" },
          link: { type: "string", description: "Its own page at the employer, or its ATS posting" },
          reason: { type: "string", description: "The operator's reason, as they gave it: it goes on the record" }
        },
        required: %w[role link reason]
      )

      class << self
        def answer(role:, link:, reason:)
          found = Lookup.role(role)
          raise Refusal, "Give the operator's reason: it goes on the record." if reason.to_s.strip.empty?

          before = found.job_url
          Verifier::Capture.own_page!(found, link, note: reason, actor: ASSISTANT)
          ProvenanceMcp.text(Writing.fence("record", "#{found.company.name} / #{found.role_title}"),
                             "Its own page is now #{found.job_url}#{" (was #{before})" if before}: each check looks for it there first. " \
                             "Role id #{found.id}.")
        end
      end
    end
  end
end
