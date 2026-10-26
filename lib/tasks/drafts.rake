namespace :drafts do
  # The kind asked for (KIND=), refused before any backup when it isn't one.
  kind = lambda do
    ENV["KIND"].to_s.tap { |value| abort "KIND is one of: #{Draft::KINDS.join(', ')}." unless Draft::KINDS.include?(value) }
  end
  find = ->(id) { Draft.includes(:llm_call, :contact, application: %i[company posting]).find_by(id: id) or abort "No draft #{id.inspect}: see drafts:list." }
  named = ->(application) { "#{application.company.name} / #{application.posting.role_title}" }
  dollars = ->(amount) { format("$%.3f", amount.to_f) }

  desc "Drafts, newest first, each with its id, where it stands and what it cost. [APPLICATION=id]"
  task list: :environment do
    drafts = Draft.includes(:llm_call, :contact, application: %i[company posting]).newest_first
    drafts = drafts.where(application_id: ENV["APPLICATION"]) if ENV["APPLICATION"].present?
    abort "No draft yet: write one from an application's page, or with drafts:write." if drafts.empty?

    drafts.each do |draft|
      puts "#{draft.id}  #{draft.created_at.to_date}  #{named.call(draft.application)}: #{draft.label.downcase}" \
           "#{" to #{draft.contact.name}" if draft.contact} in #{draft.language}, " \
           "#{draft.words} words, #{draft.approved? ? 'approved' : 'a draft'}#{', edited' if draft.edited?}" \
           "#{", #{dollars.call(draft.llm_call.cost_usd)}" if draft.llm_call}"
    end
  end

  desc "One draft: its text as it stands, what the role asks that the resume doesn't show, the lines it drew on, " \
       "and what it was written from. Usage: bin/rails \"drafts:show[id]\""
  task :show, [ :id ] => :environment do |_task, args|
    draft = find.call(args[:id])
    puts "#{draft.label} for #{named.call(draft.application)}#{", to #{draft.contact.label}" if draft.contact}, in #{draft.language}: " \
         "#{draft.approved? ? "approved #{draft.approved_at.to_date}" : 'a draft'}#{', edited by you' if draft.edited?}"
    puts "\nSubject: #{draft.subject}" if draft.subject
    puts "\n#{draft.body}"

    puts "\nWhat the role asks for that the resume doesn't show"
    puts "  nothing it found" if draft.gaps.empty?
    draft.gaps.each { |gap| puts "  - #{gap['asks']}: #{gap['note']}" }
    if draft.tailored_resume?
      puts "\nWhat it changed"
      draft.tailoring.each { |change| puts "  - #{change['change']} (lines #{change['lines'].map { |line| line['line'] }.join(', ')})" }
    else
      puts "\nWhat it drew on"
      draft.drew_on.each { |point| puts "  [#{point['line']}] #{point['text']} (#{point['used_for']})" }
    end
    puts "  #{draft.dropped_lines} more it named aren't in the resume: left out" if draft.dropped_lines.positive?
    puts "\nIts note: #{draft.notes}" if draft.notes

    call = draft.llm_call
    model = call ? " with #{call.model} for #{dollars.call(call.cost_usd)}" : (" (it reports #{draft.reported_model})" if draft.reported_model)
    puts "Revises the #{draft.revises.label.downcase} of #{draft.revises.created_at.to_date} (#{draft.revises.id})" if draft.revises
    puts "\nWritten #{draft.created_at.to_date} by #{draft.writer}#{model}, from " \
         "the resume #{draft.resume ? "saved #{draft.resume.created_at.to_date}" : '(since deleted)'} and the role's description " \
         "#{draft.role_description ? "read #{draft.role_description.first_read_at.to_date}" : '(no longer on record)'}"
    asked = [ draft.asked_language, ("to stress \"#{draft.guidance}\"" if draft.guidance) ].compact
    puts "Asked for #{asked.to_sentence}" if asked.any?
  end

  desc "Write a draft for an application as the drafter, in the foreground: one Opus 5.5 call, about what drafts cost on " \
       "record. Backs up first; nothing is sent. " \
       "Usage: KIND=cover_letter|outreach [LANGUAGE=Portuguese] [STRESS=\"...\"] [CONTACT=\"name or id\": an outreach note's] " \
       "bin/rails \"drafts:write[application_id]\""
  task :write, [ :id ] => :environment do |_task, args|
    application = Application.includes(:company, :posting).find_by(id: args[:id]) or abort "No application #{args[:id].inspect}: see applications:list."
    if ENV["CONTACT"].present?
      contact = Contacts.named(application.company, ENV["CONTACT"]) or
        abort "No contact #{ENV['CONTACT'].inspect} at #{application.company.name}: see contacts:list."
    end
    asked = { kind: kind.call, language: ENV["LANGUAGE"].to_s.strip.presence, guidance: ENV["STRESS"].to_s.strip.presence, contact: contact }
    why = Drafts.refusal(application, **asked)
    abort "#{why.upcase_first}." if why

    puts "Writing #{Draft::A_LABEL.fetch(asked[:kind])} for #{named.call(application)}#{" to #{contact.name}" if contact} with Opus 5.5: about " \
         "#{dollars.call(Drafts.estimate)}."
    puts "Backed up to #{DatabaseBackup.call}"
    written = Drafts.write!(application, **asked)
    abort "Not drafted: #{written.summary} Cost #{dollars.call(written.cost_usd)}." unless written.draft

    puts "#{written.summary} Cost #{dollars.call(written.cost_usd)}."
    puts "Read it with drafts:show[#{written.draft.id}] or on its application's page, where you edit and approve it."
  rescue ArgumentError, Verifier::Worker::Error => e
    abort e.message.upcase_first
  end

  desc "Approve a draft as it stands, audited as you; backs up first. Nothing is sent: you copy it and send it yourself. " \
       "Usage: bin/rails \"drafts:approve[id]\""
  task :approve, [ :id ] => :environment do |_task, args|
    draft = find.call(args[:id])
    abort "It is approved already, on #{draft.approved_at.to_date}." if draft.approved?

    puts "Backed up to #{DatabaseBackup.call}"
    Drafts.approve!(draft)
    puts "#{draft.label} for #{named.call(draft.application)}: approved. Nothing is sent: copy it and send it yourself."
  end
end
