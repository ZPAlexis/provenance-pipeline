namespace :contacts do
  # A contact's fields from the environment: only those given; one given empty is cleared. Not NAME or EMAIL: shells
  # set those already (WSL sets NAME to the machine's name), and an edit would take them as given.
  fields = lambda do
    { "name" => "CONTACT_NAME", "role" => "ROLE", "kind" => "KIND", "email" => "CONTACT_EMAIL", "linkedin_url" => "LINKEDIN", "notes" => "NOTES" }
      .select { |_field, variable| ENV.key?(variable) }.transform_values { |variable| ENV[variable] }
      .tap { |given| abort "KIND is one of: #{Contact::KINDS.join(', ')}." if given["kind"].present? && !Contact::KINDS.include?(given["kind"]) }
  end
  find = ->(id) { Contact.includes(:company).find_by(id: id) or abort "No contact #{id.inspect}: see contacts:list." }
  application = lambda do
    Application.includes(:company, :posting).find_by(id: ENV["APPLICATION"]) or abort "No application #{ENV['APPLICATION'].inspect}: see applications:list."
  end
  named = ->(found) { "#{found.company.name} / #{found.posting.role_title}" }

  desc "Contacts, by company, each with its id, kind, and the applications it is linked to. [COMPANY=\"Acme\"] [APPLICATION=id]"
  task list: :environment do
    contacts = Contact.includes(:company, applications: :posting)
    contacts = contacts.joins(:company).where("lower(companies.name) = ?", ENV["COMPANY"].strip.downcase) if ENV["COMPANY"].present?
    contacts = contacts.where(id: application.call.contacts.select(:id)) if ENV["APPLICATION"].present?
    abort "No contact yet: add one on a company's page, or with contacts:add." if contacts.empty?

    contacts.to_a.group_by(&:company).sort_by { |company, _| [ company.name.downcase, company.name ] }.each do |company, people|
      puts "\n#{company.name}"
      people.sort_by { |person| [ person.name.downcase, person.created_at ] }.each do |person|
        reach = [ person.email, person.linkedin_url ].compact.join(", ")
        linked = person.applications.map { |linked_one| linked_one.posting.role_title }
        puts "  #{person.id}  #{person.label}, #{person.kind_label.downcase}#{"  #{reach}" if reach.present?}" \
             "#{"  linked to: #{linked.join(', ')}" if linked.any?}"
      end
    end
  end

  desc "Add a contact at a company (or at an application's, linked to it), audited as you; backs up first. " \
       "Usage: CONTACT_NAME=\"Ana Lima\" (COMPANY=\"Acme\" | APPLICATION=id) [ROLE=] [KIND=recruiter] [CONTACT_EMAIL=] [LINKEDIN=] [NOTES=] " \
       "bin/rails contacts:add"
  task add: :environment do
    linked = application.call if ENV["APPLICATION"].present?
    company = linked&.company || (Company.find_by("lower(name) = ?", ENV["COMPANY"].to_s.strip.downcase) if ENV["COMPANY"].present?)
    abort "Name the company in COMPANY=\"...\" (as on its page), or an application in APPLICATION=id." unless company
    given = fields.call
    abort "Name them in CONTACT_NAME=\"...\"." if given["name"].blank?
    same = Contacts.named(company, given["name"])
    abort "#{same.label} is a contact at #{company.name} already (#{same.id}): change them with contacts:edit." if same

    puts "Backed up to #{DatabaseBackup.call}"
    contact = Contacts.save!(company, given, application: linked, reasoning: "From the command line.")
    puts "#{contact.label} added at #{company.name}#{", linked to #{named.call(linked)}" if linked} (#{contact.id})"
  rescue ArgumentError, ActiveRecord::RecordInvalid => e
    abort e.message.upcase_first
  end

  desc "Change a contact's details, audited as you; backs up first. Only the fields given change, and one given empty is " \
       "cleared. Usage: [CONTACT_NAME=] [ROLE=] [KIND=] [CONTACT_EMAIL=] [LINKEDIN=] [NOTES=] bin/rails \"contacts:edit[id]\""
  task :edit, [ :id ] => :environment do |_task, args|
    contact = find.call(args[:id])
    given = fields.call
    abort "Give what to change: CONTACT_NAME, ROLE, KIND, CONTACT_EMAIL, LINKEDIN or NOTES." if given.empty?

    puts "Backed up to #{DatabaseBackup.call}"
    Contacts.save!(contact.company, given, contact: contact, reasoning: "From the command line.")
    puts "#{contact.label} at #{contact.company.name}: #{contact.saved_changes.any? ? 'changed' : 'nothing to change'}"
  rescue ArgumentError, ActiveRecord::RecordInvalid => e
    abort e.message.upcase_first
  end

  desc "Link a contact to an application at its company, audited as you; backs up first. " \
       "Usage: APPLICATION=id bin/rails \"contacts:link[id]\""
  task :link, [ :id ] => :environment do |_task, args|
    contact = find.call(args[:id])
    linked = application.call
    abort "#{contact.name} is linked to #{named.call(linked)} already." if linked.contacts.include?(contact)

    puts "Backed up to #{DatabaseBackup.call}"
    Contacts.link!(contact, linked)
    puts "#{contact.label} linked to #{named.call(linked)}"
  rescue ActiveRecord::RecordInvalid => e
    abort e.message.upcase_first
  end

  desc "Unlink a contact from an application; they stay with the company. Audited as you; backs up first. " \
       "Usage: APPLICATION=id bin/rails \"contacts:unlink[id]\""
  task :unlink, [ :id ] => :environment do |_task, args|
    contact = find.call(args[:id])
    linked = application.call
    abort "#{contact.name} isn't linked to #{named.call(linked)}." unless linked.contacts.include?(contact)

    puts "Backed up to #{DatabaseBackup.call}"
    Contacts.unlink!(contact, linked)
    puts "#{contact.label} unlinked from #{named.call(linked)}; still a contact at #{contact.company.name}"
  end

  desc "Delete a contact, audited as you (their details by hash alone); backs up first. Their links go; activities and " \
       "outreach notes stay, naming no one. Only you can. Usage: bin/rails \"contacts:delete[id]\""
  task :delete, [ :id ] => :environment do |_task, args|
    contact = find.call(args[:id])

    puts "Backed up to #{DatabaseBackup.call}"
    Contacts.delete!(contact)
    puts "#{contact.label} at #{contact.company.name}: #{AuditEvent.where(target: contact, action: 'destroy').order(:occurred_at).last.reasoning}"
  end
end
