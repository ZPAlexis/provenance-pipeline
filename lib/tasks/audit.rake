namespace :audit do
  desc "The audit log, newest first, narrowed as on the Audit log page: who made each write, under which credential, " \
       "what it changed, and why. Read-only. [WHO=operator|agents|verifier...] [KIND=role|company|review_item...] " \
       "[ACTION=create|update|destroy|denied] [ATTRIBUTE=verification_state] [FROM=2026-10-01] [TO=2026-10-28] " \
       "[RECORD=id] [CREDENTIAL=id] [PAGE=1]"
  task list: :environment do
    log = AuditLog.new(**AuditLog::FILTERS.to_h { |filter| [ filter, ENV[filter.to_s.upcase].presence ] })
    abort "No event matches#{" (#{log.description})" if log.filtered?}." if log.count.zero?

    page = (ENV["PAGE"].presence || 1).to_i.clamp(1, log.pages)
    events = log.page(page)
    puts "#{log.count} #{log.count == 1 ? 'event' : 'events'}#{" (#{log.description})" if log.filtered?}, newest first; " \
         "page #{page} of #{log.pages}. Times are UTC."
    puts "By: #{log.by_who.map { |who, count| "#{who.delete_prefix('agent:')} #{count}" }.join(', ')}" unless log.who
    events.each { |event| puts "", AuditLog.describe(event) }
    puts "\nOlder: PAGE=#{page + 1}" if page < log.pages
  rescue ArgumentError => e
    abort e.message.upcase_first
  end
end
