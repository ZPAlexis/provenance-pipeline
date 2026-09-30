namespace :postings do
  desc "Move a posting to the company really hiring, e.g. one sourced through an aggregator. Audited as you. " \
       "Usage: REASON=\"...\" bin/rails \"postings:move[posting_id,Company Name,domain.com]\""
  task :move, [ :posting_id, :name, :domain ] => :environment do |_task, args|
    posting = Posting.find_by(id: args[:posting_id]) or abort "No posting #{args[:posting_id].inspect}."
    abort "Name the company: postings:move[posting_id,Company Name,domain.com]" if args[:name].blank?
    reason = ENV["REASON"].presence or abort "Say why in REASON=\"...\": it becomes the audit reasoning."

    # A human correction cannot be regenerated from source, so it is backed up like any batch that writes.
    puts "Backed up to #{DatabaseBackup.call}"
    from = posting.company.name
    to = PostingReassignment.call(posting, name: args[:name], domain: args[:domain].presence,
                                           actor: AuditEvent::OPERATOR, reasoning: reason)
    puts "#{posting.role_title}: #{from} -> #{to.name}#{" (careers page #{to.careers_page_url})" if to.careers_page_url}"
  rescue ArgumentError => e
    abort e.message
  end
end
