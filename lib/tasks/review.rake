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
end
