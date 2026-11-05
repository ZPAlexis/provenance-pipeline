module ProvenanceMcp
  module Tools
    # Roles tracked or archived on the operator's word (4a step 4): as agent:assistant, under a credential for this
    # one call holding watchlist:curate, through the same service as the app's buttons, with the operator's reason on
    # the record. All or none.
    class TrackOrArchiveRoles < SaveTool
      MAX = 50

      tool_name "track_or_archive_roles"
      title "Track or archive roles"
      description "Tracks or archives roles, only when the operator tells you to, with their reason: a tracked role is " \
                  "looked for at every check of its company's careers page; an archived one is never checked or " \
                  "suggested again. A suggested role can be either. All or none: a role at an archived company is " \
                  "tracked only once the company is (track_or_archive_companies), and then nothing changes. Those already " \
                  "so are left as they are. Up to #{MAX} a call. Recorded as yours, with the reason."
      scopes "watchlist:curate"
      input_schema(
        properties: {
          roles: { type: "array", items: { type: "string" },
                   description: "Each by its id (from get_company_status), or its company and title" },
          action: { type: "string", enum: %w[track archive] },
          reason: { type: "string", description: "The operator's reason, as they gave it: it goes on the record" }
        },
        required: %w[roles action reason]
      )

      class << self
        def answer(roles:, action:, reason:)
          raise Refusal, "action is track or archive." unless %w[track archive].include?(action)
          raise Refusal, "Give the operator's reason: it goes on the record." if reason.to_s.strip.empty?

          names = Array(roles).map { |name| name.to_s.strip }.reject(&:empty?).uniq
          raise Refusal, "Name the roles to #{action}." if names.empty?
          raise Refusal, "At most #{MAX} roles a call." if names.size > MAX

          found = names.map { |name| Lookup.role(name) }.uniq
          want = action == "archive" ? "dismissed" : "tracked"
          already, change = found.partition { |role| role.tracking == want }
          if action == "track" && (held = change.find { |role| role.company.dismissed? })
            raise Refusal, "Nothing changed: #{held.company.name} is archived: track the company first, with track_or_archive_companies."
          end

          ApplicationRecord.transaction { change.each { |role| decide!(role, action, reason.strip) } }
          said(action, change, already)
        end

        private

        def decide!(role, action, reason)
          if action == "archive"
            Verifier::Tracking.dismiss!(role, note: reason, actor: ASSISTANT)
          else
            Verifier::Tracking.track!(role, note: reason, actor: ASSISTANT)
          end
        end

        def said(action, changed, already)
          word = action == "archive" ? "archived" : "tracked"
          lines = changed.map { |role| "- #{role.company.name} / #{role.role_title}: #{word}" } +
                  already.map { |role| "- #{role.company.name} / #{role.role_title}: already #{word}, left as it is" }
          what = action == "archive" ? "never checked or suggested again until tracked" : "looked for at every check of its company's careers page"
          ProvenanceMcp.text("#{changed.size} #{changed.one? ? 'role' : 'roles'} #{word} on the operator's word, the reason on the " \
                             "record: #{what}.", Writing.fence("record", lines.join("\n")))
        end
      end
    end
  end
end
