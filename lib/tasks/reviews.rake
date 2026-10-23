namespace :reviews do
  find = ->(id) { ResumeReview.includes(:llm_call, application: %i[company posting]).find_by(id: id) or abort "No review #{id.inspect}: see reviews:list." }
  named = ->(application) { "#{application.company.name} / #{application.posting.role_title}" }
  dollars = ->(amount) { format("$%.3f", amount.to_f) }
  numbers = ->(cited) { cited.map { |line| line["line"] }.join(", ") }

  desc "Resume reviews, newest first, each with its id, who wrote it, and what it cost. [APPLICATION=id]"
  task list: :environment do
    reviews = ResumeReview.includes(:llm_call, application: %i[company posting]).newest_first
    reviews = reviews.where(application_id: ENV["APPLICATION"]) if ENV["APPLICATION"].present?
    abort "No review yet: write one from an application's page, with reviews:write, or from your Claude client through MCP." if reviews.empty?

    reviews.each do |review|
      puts "#{review.id}  #{review.created_at.to_date}  #{named.call(review.application)}: #{review.language}, " \
           "#{review.strengths.size} strengths, #{review.gaps.size} gaps, #{review.suggestions.size} suggestions; " \
           "by #{review.writer}#{", #{dollars.call(review.llm_call.cost_usd)}" if review.llm_call}"
    end
  end

  desc "One review: its strengths and gaps, its suggestions, each with its resume lines, its note, and what it was written from. " \
       "Usage: bin/rails \"reviews:show[id]\""
  task :show, [ :id ] => :environment do |_task, args|
    review = find.call(args[:id])
    puts "Resume review for #{named.call(review.application)}, in #{review.language}"
    puts "\nStrengths"
    review.strengths.each { |strength| puts "  - #{strength['point']} (lines #{numbers.call(strength['lines'])})" }
    puts "\nGaps"
    puts "  none found" if review.gaps.empty?
    review.gaps.each { |gap| puts "  - #{gap['asks']}: #{gap['note']}" }
    puts "\nSuggestions"
    review.suggestions.each { |suggestion| puts "  - #{suggestion['change']} (lines #{numbers.call(suggestion['lines']).presence || 'none'})" }
    puts "  #{review.dropped_lines} more lines it named aren't in the resume: left out" if review.dropped_lines.positive?
    puts "\nIts note: #{review.note}" if review.note

    call = review.llm_call
    model = call ? " with #{call.model} for #{dollars.call(call.cost_usd)}" : (" (it reports #{review.reported_model})" if review.reported_model)
    puts "\nWritten #{review.created_at.to_date} by #{review.writer}#{model}, from the resume " \
         "#{review.resume ? "saved #{review.resume.created_at.to_date}" : '(since deleted)'} and the role's description " \
         "#{review.role_description ? "read #{review.role_description.first_read_at.to_date}" : '(no longer on record)'}"
  end

  desc "Review the resume against an application's role as the drafter, in the foreground: one Opus 5.5 call, about what " \
       "reviews cost on record. Backs up first. Usage: [LANGUAGE=Portuguese] bin/rails \"reviews:write[application_id]\""
  task :write, [ :id ] => :environment do |_task, args|
    application = Application.includes(:company, :posting).find_by(id: args[:id]) or abort "No application #{args[:id].inspect}: see applications:list."
    language = ENV["LANGUAGE"].to_s.strip.presence
    why = ResumeReviews.refusal(application, language:)
    abort "#{why.upcase_first}." if why

    puts "Reviewing the resume against #{named.call(application)} with Opus 5.5: about #{dollars.call(ResumeReviews.estimate)}."
    puts "Backed up to #{DatabaseBackup.call}"
    written = ResumeReviews.write!(application, language:)
    abort "Not reviewed: #{written.summary} Cost #{dollars.call(written.cost_usd)}." unless written.review

    puts "#{written.summary} Cost #{dollars.call(written.cost_usd)}."
    puts "Read it with reviews:show[#{written.review.id}] or on its application's page."
  rescue ArgumentError, Verifier::Worker::Error => e
    abort e.message.upcase_first
  end
end
