namespace :review do
  desc "Bring the review queue in line with the record: raise what each company's record asks of you, close what it " \
       "no longer asks. No API cost; backs up first."
  task sync: :environment do
    puts "Backed up to #{DatabaseBackup.call}"
    before = ReviewItem.open.count
    Company.find_each { |company| ReviewQueue.sync!(company) }
    open = ReviewItem.open.group(:kind).count
    puts "Open items: #{before} -> #{open.values.sum}. #{open.map { |kind, count| "#{kind.humanize}: #{count}" }.join('; ')}"
  end

  desc "List what is waiting for your judgment, oldest first, with each item's id. [KIND=no_careers_page]"
  task list: :environment do
    helpers = ApplicationController.helpers
    items = ReviewItem.open.includes(:company, :subject).oldest_first
    items = items.where(kind: ENV["KIND"]) if ENV["KIND"].present?
    abort "Nothing to review#{" of kind #{ENV['KIND']}" if ENV['KIND'].present?}." if items.empty?

    items.each do |item|
      puts "\n#{item.id}  [#{helpers.review_kind_label(item.kind)}]  #{helpers.review_question(item)}"
      puts "  #{item.evidence.truncate(300)}"
      puts "  Proposed: #{helpers.review_proposal(item)}   (raised by #{item.raised_by}, #{item.created_at.to_date})"
    end
    puts "\n#{items.size} open. Decide one with: DECISION=... [NOTE=\"...\"] [URL=...] [KIND=...] " \
         "bin/rails \"review:decide[item_id]\" (#{ReviewQueue::DECISIONS.join(', ')})"
  end

  desc "Decide one item, as on the Review page, audited as you; backs up first. A check asked for runs now and prints " \
       "what it found. Usage: DECISION=confirm|reject|set_page|set_kind|find_again|check_again|still_listed|" \
       "no_longer_listed|undo|leave [NOTE=\"...\"] [URL=...] [KIND=...] bin/rails \"review:decide[item_id]\""
  task :decide, [ :id ] => :environment do |_task, args|
    item = ReviewItem.includes(:company, :subject).find_by(id: args[:id]) or abort "No review item #{args[:id].inspect}: see review:list."
    decision = ENV["DECISION"].to_s
    # Refused before anything is backed up or written.
    abort "That item is already decided (#{item.decision})." unless item.status == "open"
    abort "Give DECISION=, one of: #{ReviewQueue::DECISIONS.join(', ')}." unless ReviewQueue::DECISIONS.include?(decision)
    abort "Say why you leave it as is in NOTE=\"...\": it goes on the record." if decision == "leave" && ENV["NOTE"].blank?

    puts "Backed up to #{DatabaseBackup.call}"
    # From the command line a check runs now, in the foreground: there is no server to run it in the background.
    check = lambda do |record|
      build = ->(name) { Verifier::Worker.new(run_dir: Verifier::Worker.dir_for(name)) }
      ceiling = Verifier::CheckNow.ceiling(record)
      puts format("Checking it now: at most about $%.2f.", ceiling) if ceiling.positive?
      outcome = if record.is_a?(Posting)
        Verifier::CheckNow.role(record, worker: build.call("check"), finder: build.call("resolve"))
      else
        Verifier::CheckNow.company(record, worker: build.call("verify"), finder: build.call("resolve"))
      end
      format("%s%s Cost: est. $%.4f. The item is %s.   (details: %s)", outcome.finished? ? "" : "Stopped. ", outcome.summary,
             outcome.cost_usd, item.reload.status == "open" ? "still open" : "closed", outcome.run_dir)
    end
    puts ReviewQueue.act!(item, decision, note: ENV["NOTE"], url: ENV["URL"], kind: ENV["KIND"], check: check)
  rescue ArgumentError, Verifier::Candidates::NotACandidate, ActiveRecord::RecordInvalid => e
    abort e.message.upcase_first
  rescue Verifier::Ingest::InvalidResult => e
    abort "NOT RECORDED, breaks the result contract: #{e.message}"
  end
end
