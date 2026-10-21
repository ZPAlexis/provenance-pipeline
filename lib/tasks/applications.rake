namespace :applications do
  # The day it happened (ON=YYYY-MM-DD), today when not given; a wrong one is refused before any backup.
  day = lambda do
    ENV["ON"].present? ? Date.iso8601(ENV["ON"]) : Date.current
  rescue Date::Error
    abort "ON is a date like #{Date.current.iso8601}."
  end
  # A stage is reached on a day that has come: refused before any backup, as Pipeline would refuse it.
  stage_day = lambda do
    day.call.tap { |on| abort "A stage is reached on a day that has come: #{on} is still ahead." if on > Date.current }
  end
  days = ->(application) { "#{application.days_in_stage} #{'day'.pluralize(application.days_in_stage)}" }
  stage = lambda do
    ENV["STAGE"].to_s.tap do |value|
      abort "STAGE is one of: #{Application::STAGES.join(', ')}." unless Application::STAGES.include?(value)
    end
  end

  desc "The pipeline: open applications by stage, then the closed ones, each with its id. [STAGE=interviewing]"
  task list: :environment do
    applications = Application.includes(:company, :posting).order(:stage_changed_on)
    applications = applications.where(stage: stage.call) if ENV["STAGE"].present?
    abort "No application#{" at #{ENV['STAGE']}" if ENV['STAGE'].present?} yet: start one with applications:start." if applications.empty?

    applications.group_by(&:stage).sort_by { |at, _| Application::STAGES.index(at) }.each do |at, group|
      puts "\n#{Application.stage_label(at)} (#{group.size})"
      group.each do |application|
        puts "  #{application.id}  #{application.company.name} / #{application.posting.role_title}  " \
             "since #{application.stage_changed_on} (#{days.call(application)})"
      end
    end
  end

  desc "One application: its stage, the role's answer, notes, and its timeline. Usage: bin/rails \"applications:show[id]\""
  task :show, [ :id ] => :environment do |_task, args|
    application = Application.includes(:company, :posting).find_by(id: args[:id]) or abort "No application #{args[:id].inspect}: see applications:list."
    role = application.posting
    puts "#{application.company.name} / #{role.role_title}"
    puts "  #{Application.stage_label(application.stage)} since #{application.stage_changed_on} (#{days.call(application)}); " \
         "the role: #{Posting::ANSWER_LABELS.fetch(role.verification_state, role.verification_state).downcase}"
    puts "  Pay expectation: #{application.comp_expectation}" if application.comp_expectation
    puts "  Notes: #{application.notes}" if application.notes
    puts "\nTimeline"
    Pipeline.timeline(application).each do |entry|
      what = entry.stage ? "#{entry.from ? "#{Application.stage_label(entry.from)} -> " : 'started at '}#{Application.stage_label(entry.stage)}" : entry.activity.kind
      puts "  #{entry.on}  #{what}: #{entry.note}"
    end
  end

  desc "Start an application for a role (tracked first if it isn't), audited as you; backs up first. " \
       "Usage: [STAGE=applied] [ON=YYYY-MM-DD] [NOTE=\"...\"] bin/rails \"applications:start[posting_id]\""
  task :start, [ :id ] => :environment do |_task, args|
    role = Posting.includes(:company).find_by(id: args[:id]) or abort "No role #{args[:id].inspect}: its id is on its page."
    at = ENV["STAGE"].present? ? stage.call : "interested"
    on = stage_day.call
    abort "#{role.role_title} already has an application: #{role.application.id}." if role.application

    puts "Backed up to #{DatabaseBackup.call}"
    application = Pipeline.start!(role, stage: at, on: on, note: ENV["NOTE"])
    puts "#{role.company.name} / #{role.role_title}: started at #{Application.stage_label(at)} on #{on} (#{application.id})"
    # Its description, for the drafter: read now, since a command has no background queue (free, never the LLM).
    if role.job_url
      read = Verifier::Descriptions.read!(role, purpose: "describe: #{role.role_title} at #{role.company.name}").sole
      puts "  Its description: #{read.summary}"
    end
  rescue ArgumentError => e
    abort e.message.upcase_first
  end

  desc "Move an application to a stage on the day it happened, audited as you; backs up first. Only you can. " \
       "Usage: STAGE=interviewing [ON=YYYY-MM-DD] [NOTE=\"...\"] bin/rails \"applications:move[id]\""
  task :move, [ :id ] => :environment do |_task, args|
    application = Application.includes(:company, :posting).find_by(id: args[:id]) or abort "No application #{args[:id].inspect}: see applications:list."
    to = stage.call
    on = stage_day.call

    puts "Backed up to #{DatabaseBackup.call}"
    Pipeline.move!(application, to, on: on, note: ENV["NOTE"])
    puts "#{application.company.name} / #{application.posting.role_title}: #{Application.stage_label(to)} since #{on}"
  rescue ArgumentError => e
    abort e.message.upcase_first
  end

  desc "Log what happened on an application, audited as you; backs up first. " \
       "Usage: KIND=applied|email|call|interview|assessment|offer|note|other SUMMARY=\"...\" [ON=YYYY-MM-DD] " \
       "bin/rails \"applications:log[id]\""
  task :log, [ :id ] => :environment do |_task, args|
    application = Application.includes(:company, :posting).find_by(id: args[:id]) or abort "No application #{args[:id].inspect}: see applications:list."
    kind = ENV["KIND"].to_s
    abort "KIND is one of: #{Activity::KINDS.join(', ')}." unless Activity::KINDS.include?(kind)
    abort "Say what happened in SUMMARY=\"...\"." if ENV["SUMMARY"].blank?
    on = day.call

    puts "Backed up to #{DatabaseBackup.call}"
    Pipeline.log!(application, kind: kind, summary: ENV["SUMMARY"], on: on)
    puts "#{application.company.name} / #{application.posting.role_title}: #{kind} on #{on} logged"
  rescue ArgumentError, ActiveRecord::RecordInvalid => e
    abort e.message.upcase_first
  end
end
