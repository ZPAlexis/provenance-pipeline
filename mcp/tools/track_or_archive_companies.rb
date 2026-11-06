module ProvenanceMcp
  module Tools
    # Companies tracked or archived on the operator's word (4a step 4): as agent:assistant, under a credential for
    # this one call holding watchlist:curate, through the same service as the app's buttons, with the operator's
    # reason on the record. Archiving takes the company's roles in play with it; tracking it again brings them back.
    # All or none, as "Archive selected" on the Companies page.
    class TrackOrArchiveCompanies < SaveTool
      MAX = 50

      tool_name "track_or_archive_companies"
      title "Track or archive companies"
      description "Tracks or archives companies on the watch list, only when the operator tells you to, with their " \
                  "reason. An archived company is never checked, suggested from or reviewed again, and its tracked and " \
                  "suggested roles are archived with it; tracking it again brings those roles back as they were (unless " \
                  "with_roles is false). All or none: a company with an open application can't be archived, and then " \
                  "nothing changes. Those already so are left as they are. Up to #{MAX} a call. Recorded as yours, with " \
                  "the reason; the operator undoes it in the app, or asks you to."
      scopes "watchlist:curate"
      input_schema(
        properties: {
          companies: { type: "array", items: { type: "string" },
                       description: "Each by its id (from list_companies), its name, its domain, or a link on its site" },
          action: { type: "string", enum: %w[track archive] },
          reason: { type: "string", description: "The operator's reason, as they gave it: it goes on the record" },
          with_roles: { type: "boolean", description: "Tracking again: bring back the roles archived with it (true unless said)" }
        },
        required: %w[companies action reason]
      )

      class << self
        def answer(companies:, action:, reason:, with_roles: true)
          raise Refusal, "action is track or archive." unless %w[track archive].include?(action)
          raise Refusal, "Give the operator's reason: it goes on the record." if reason.to_s.strip.empty?

          names = Array(companies).map { |name| name.to_s.strip }.reject(&:empty?).uniq
          raise Refusal, "Name the companies to #{action}." if names.empty?
          raise Refusal, "At most #{MAX} companies a call." if names.size > MAX

          found = names.map { |name| Lookup.company(name) }.uniq
          want = action == "archive" ? "dismissed" : "tracked"
          already, change = found.partition { |company| company.tracking == want }
          # Whether each was a proposal (4b) is read before it changes: tracking one has its board read once this commits.
          done = ApplicationRecord.transaction do
            change.map { |company| [ company, company.suggested?, decide!(company, action, reason.strip, with_roles) ] }
          end
          said(action, done, already)
        rescue ArgumentError => e # an open application, said by the service: nothing changed
          raise Refusal, "Nothing changed: #{e.message}."
        end

        private

        def decide!(company, action, reason, with_roles)
          if action == "archive"
            Verifier::Tracking.dismiss_company!(company, note: reason, actor: ASSISTANT)
          else
            Verifier::Tracking.track_company!(company, note: reason, with_roles: with_roles != false, actor: ASSISTANT)
          end
        end

        def said(action, done, already)
          went = action == "archive" ? "archived with it" : "back with it"
          lines = done.map { |company, proposal, roles| proposal ? proposal_said(action, company) : "- #{company.name}: #{roles.size} #{roles.one? ? 'role' : 'roles'} #{went}" } +
                  already.map { |company| "- #{company.name}: already #{action == 'archive' ? 'archived' : 'tracked'}, left as it is" }
          what = action == "archive" ? "never checked, suggested from or reviewed again until tracked" : "checked, suggested from and reviewed again"
          ProvenanceMcp.text("#{done.size} #{done.one? ? 'company' : 'companies'} #{action == 'archive' ? 'archived' : 'tracked'} on the " \
                             "operator's word, the reason on the record: #{what}.", Writing.fence("record", lines.join("\n")))
        end

        # A company proposed to the operator (4b): declined, or tracked with its board read now, free.
        def proposal_said(action, company)
          return "- #{company.name}: a proposal, declined: never proposed again" if action == "archive"
          return "- #{company.name}: a proposal, tracked; it names no known board, so Check now finds its careers page" unless Verifier::BoardRead.link(company)

          "- #{company.name}: a proposal, tracked; the board it was proposed with is being read now, free (see get_company_status in a minute)"
        end
      end
    end
  end
end
