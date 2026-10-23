module ProvenanceMcp
  module Tools
    # The people at a company the operator deals with, or those linked to one application.
    class ListContacts < ReadTool
      tool_name "list_contacts"
      title "Contacts"
      description "The contacts at a company, or the ones linked to an application: each one's name, role, kind (recruiter, " \
                  "hiring manager, referrer, interviewer, other), how to reach them, notes, the applications they are " \
                  "linked to, and their id (what save_contact and log_activity take). Name a company or an application."
      input_schema(properties: {
        company: { type: "string", description: "Its name, domain, or a link on its site" },
        application: { type: "string", description: "Its id, or its company and role" }
      })

      class << self
        def answer(company: nil, application: nil)
          raise Refusal, "Name a company or an application." if company.blank? && application.blank?

          found = Lookup.application(application) if application.present?
          contacts = (found ? found.contacts : Lookup.company(company).contacts).includes(applications: :posting).to_a
          where = found ? "linked to #{Writing.label(found)}" : "at #{Lookup.company(company).name}"
          return ProvenanceMcp.text("No contacts #{where} yet.") if contacts.empty?

          ProvenanceMcp.text(contacts.map { |contact| line(contact) })
        end

        private

        def line(contact)
          reach = [ contact.email, contact.linkedin_url ].compact_blank.join(", ").presence
          linked = contact.applications.map { |application| application.posting.role_title }.join(", ").presence
          "- #{contact.label}, #{contact.kind_label.downcase}#{"; #{reach}" if reach}#{"; linked to #{linked}" if linked}" \
            "#{"; notes: #{contact.notes}" if contact.notes.present?}; contact id #{contact.id}"
        end
      end
    end
  end
end
