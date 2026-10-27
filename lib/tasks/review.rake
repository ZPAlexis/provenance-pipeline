namespace :review do
  # From the command line a check runs now, in the foreground: there is no server to run it in the background.
  foreground_check = lambda do |item|
    lambda do |record|
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
  end

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
      next unless item.recommended?

      said = item.recommendation
      puts "  Recommended: #{ReviewRecommendations.said(said)} (#{said['confidence']} confidence; #{said['by']}, #{said['at'].to_s.first(10)})"
      puts "    #{said['reasoning'].to_s.truncate(300)}"
    end
    puts "\n#{items.size} open. Decide one with: DECISION=... [NOTE=\"...\"] [URL=...] [KIND=...] " \
         "bin/rails \"review:decide[item_id]\" (#{ReviewQueue::DECISIONS.join(', ')})"
  end

  desc "Accept an item's recommendation, as the Review page's Accept does: its action carried out as your decision, " \
       "noting you followed it; backs up first. A check it recommends runs now. Usage: bin/rails \"review:accept[item_id]\""
  task :accept, [ :id ] => :environment do |_task, args|
    item = ReviewItem.includes(:company, :subject).find_by(id: args[:id]) or abort "No review item #{args[:id].inspect}: see review:list."
    abort "That item is already decided (#{item.decision})." unless item.status == "open"
    abort "That item carries no recommendation: decide it with review:decide." unless item.recommended?

    puts "Accepting: #{ReviewRecommendations.said(item.recommendation)}."
    puts "Backed up to #{DatabaseBackup.call}"
    puts ReviewRecommendations.accept!(item, check: foreground_check.call(item))
  rescue ArgumentError, Verifier::Candidates::NotACandidate, ActiveRecord::RecordInvalid => e
    abort e.message.upcase_first
  rescue Verifier::Ingest::InvalidResult => e
    abort "NOT RECORDED, breaks the result contract: #{e.message}"
  end

  desc "How the recommendations on review items came out, per kind: agreed (you did as recommended), differed, resolved " \
       "(the record settled it first), and pending (still open). Read-only."
  task agreement: :environment do
    agreement = ReviewRecommendations.agreement
    abort "No item has carried a recommendation yet." if agreement.empty?

    agreement.sort.each do |kind, tally|
      decided = tally.fetch("agreed", 0) + tally.fetch("differed", 0)
      rate = decided.positive? ? " (#{(100.0 * tally.fetch('agreed', 0) / decided).round}% of those you decided)" : ""
      counts = ReviewRecommendations::OUTCOMES.filter_map { |outcome| "#{tally[outcome]} #{outcome}" if tally[outcome] }
      puts "#{ReviewGuidance.label(kind)}: #{counts.join(', ')}#{rate}"
    end
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
    puts ReviewQueue.act!(item, decision, note: ENV["NOTE"], url: ENV["URL"], kind: ENV["KIND"], check: foreground_check.call(item))
  rescue ArgumentError, Verifier::Candidates::NotACandidate, ActiveRecord::RecordInvalid => e
    abort e.message.upcase_first
  rescue Verifier::Ingest::InvalidResult => e
    abort "NOT RECORDED, breaks the result contract: #{e.message}"
  end
end
