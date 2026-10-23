module ProvenanceMcp
  module Tools
    # A contact the operator tells the client about, saved when they say so (2e): added at a company, or one of its
    # contacts updated; linked to an application when one is named. As agent:assistant, under a credential for this
    # one call holding contacts:write. Deleting one stays the operator's.
    class SaveContact < SaveTool
      tool_name "save_contact"
      title "Save a contact"
      description "Adds a contact at a company, or updates one of its contacts (name it in `contact`), only when the " \
                  "operator asks: someone they deal with about a role, from what they tell you or paste (a LinkedIn " \
                  "message, an email signature). Name the application to link it to, or the company. Give only what " \
                  "you were told: never guess an email or a link."
      scopes "contacts:write"
      # Contact::KINDS, written out: a tool's file loads before Rails boots (a spec keeps them in step).
      KINDS = %w[recruiter hiring_manager referrer interviewer other].freeze

      input_schema(
        properties: {
          application: { type: "string", description: "The application to link it to: its id, or its company and role" },
          company: { type: "string", description: "Or the company, when it is for no application yet" },
          contact: { type: "string", description: "To update one: the contact's id or name; leave it out to add one" },
          name: { type: "string" },
          role: { type: "string", description: "Their role at the company: \"Technical Recruiter\"" },
          kind: { type: "string", enum: KINDS },
          email: { type: "string" },
          linkedin_url: { type: "string", description: "Their LinkedIn profile's address" },
          notes: { type: "string", description: "How the operator knows them, what they care about" }
        }
      )

      class << self
        def answer(application: nil, company: nil, contact: nil, **fields)
          raise Refusal, "Name the application to link it to, or the company." if application.blank? && company.blank?

          found = Lookup.application(application) if application.present?
          at = found&.company || Lookup.company(company)
          existing = Lookup.contact(at, contact) if contact.present?
          given = fields.slice(:name, :role, :kind, :email, :linkedin_url, :notes).compact
          refuse_a_second!(at, given[:name]) unless existing
          saved = Contacts.save!(at, given, contact: existing, application: found, actor: ASSISTANT, reasoning: "Saved through MCP.")
          ProvenanceMcp.text("#{existing ? 'Updated' : 'Added'} #{saved.label} at #{at.name}" \
                             "#{", linked to #{Writing.label(found)}" if found}. Contact id #{saved.id}.")
        end

        private

        # The same person twice is one contact: say who is there already, to update them instead.
        def refuse_a_second!(company, name)
          raise Refusal, "A new contact needs a name." if name.blank?

          same = company.contacts.find_by("lower(contacts.name) = ?", name.to_s.strip.downcase)
          raise Refusal, "#{same.label} is a contact at #{company.name} already (contact id #{same.id}): name them in contact to update them." if same
        end
      end
    end
  end
end
