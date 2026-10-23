# The people at a company the operator deals with (Stage 2e): written by the operator on the pages, or (2e
# step 2) by the operator's own Claude client through MCP. A contact is kept with its company and linked to any
# of its applications. Its personal details (name, email, link, notes) are audited as hashes, never as values,
# so deleting a contact removes it from the record; its role and kind are audited as they are. Deleting one is
# the operator's alone.
module Contacts
  FIELDS = %w[name role kind email linkedin_url notes].freeze

  module_function

  # Adds a contact at `company`, or updates `contact` with what is given; links it to `application` when one is given.
  def save!(company, attributes, contact: nil, application: nil, actor: AuditEvent::OPERATOR, reasoning: "On the operator's pages.")
    attributes = clean(attributes)
    ApplicationRecord.transaction do
      contact ||= company.contacts.new(kind: "other")
      raise ArgumentError, "that contact is at another company" if contact.persisted? && contact.company_id != company.id

      created = contact.new_record?
      contact.assign_attributes(attributes)
      if contact.changed?
        contact.save!
        AuditEvent.record!(actor: actor, action: created ? "create" : "update", target: contact, reasoning: "Contact #{created ? 'added' : 'updated'}. #{reasoning}",
                           changes_made: audited(contact.saved_changes))
      end
      link!(contact, application, actor: actor) if application
      contact
    end
  end

  # Links `contact` to `application`, at the same company; nothing when it is linked already.
  def link!(contact, application, actor: AuditEvent::OPERATOR)
    return if application.application_contacts.exists?(contact: contact)

    link = application.application_contacts.create!(contact: contact)
    AuditEvent.record_write!(link, actor: actor, reasoning: "Contact linked to the application.")
    link
  end

  def unlink!(contact, application, actor: AuditEvent::OPERATOR)
    link = application.application_contacts.find_by!(contact: contact)
    ApplicationRecord.transaction do
      AuditEvent.record_destroy!(link, actor: actor, reasoning: "Contact unlinked from the application.")
      link.destroy!
    end
  end

  # The operator's deletion: the contact, its links, and its name on activities and outreach notes, which keep what they said.
  def delete!(contact, actor: AuditEvent::OPERATOR)
    links, activities, notes = contact.application_contacts.count, contact.activities.count, contact.drafts.count
    ApplicationRecord.transaction do
      AuditEvent.record!(actor: actor, action: "destroy", target: contact,
                         changes_made: audited(contact.attributes.transform_values { |value| [ value, nil ] }),
                         reasoning: "Contact deleted, with #{links} #{'link'.pluralize(links)} to applications; " \
                                    "#{activities} #{'activity'.pluralize(activities)} no longer #{activities == 1 ? 'names' : 'name'} it." \
                                    "#{" #{notes} outreach #{'note'.pluralize(notes)} addressed to them #{notes == 1 ? 'is' : 'are'} now to no one on record." if notes.positive?}")
      contact.destroy!
    end
  end

  # What a contact's audit events say: its personal details by a hash alone, everything else as it is.
  def audited(changes)
    changes.except("id", "created_at", "updated_at").to_h do |field, (before, after)|
      Contact::PERSONAL.include?(field) ? [ field, [ digest(before), digest(after) ] ] : [ field, [ before, after ] ]
    end
  end

  def digest(value) = (Resume.digest(value) if value.present?)

  # What a form or a client gives, as a contact's fields: trimmed, a blank one cleared.
  def clean(attributes)
    attributes.to_h.transform_keys(&:to_s).slice(*FIELDS).transform_values { |value| value.to_s.strip.presence }.tap do |fields|
      fields.delete("kind") if fields.key?("kind") && fields["kind"].nil?
    end
  end

  private_class_method :audited, :digest, :clean
end
