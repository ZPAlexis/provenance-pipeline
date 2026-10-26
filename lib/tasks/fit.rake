namespace :fit do
  dollars = ->(amount) { format("$%.3f", amount.to_f) }
  named = ->(posting) { "#{posting.company.name} / #{posting.role_title}" }
  find = ->(id) { Posting.includes(:company).find_by(id: id) or abort "No role #{id.inspect}: its id is on its page." }
  # Descriptions first, for the roles that have a page of their own but none on record: free, never the LLM.
  describe = lambda do |postings|
    missing = FitScores.undescribed(postings)
    return if missing.empty?

    puts "Reading #{missing.one? ? 'its description' : "#{missing.size} descriptions"} first (free, never the LLM)."
    Verifier::Descriptions.read!(missing, purpose: "fit: descriptions to weigh").each do |read|
      puts "  #{named.call(read.posting)}: #{read.summary}" unless read.outcome == "ok"
    end
  end
  report = lambda do |weighed|
    puts "#{weighed.summary} Cost #{dollars.call(weighed.cost_usd)}."
    weighed.unweighed.each { |posting, why| puts "  not weighed, #{named.call(posting)}: #{why}" }
  end

  desc "Weigh how well roles fit your resume, from each role's own description (2f): one Haiku 4.5 call a role. One role " \
       "by its id; or the unscored (no score yet, or the resume or description changed since), tracked or suggested and " \
       "not known to be gone, as a plan with its cost, run with GO=1. Backs up first. " \
       "Usage: bin/rails \"fit:score[posting_id]\" or [LIMIT=n] [GO=1] bin/rails fit:score"
  task :score, [ :id ] => :environment do |_task, args|
    roles = args[:id].present? ? [ find.call(args[:id]) ] : FitScores.unscored(FitScores.offered.includes(:company).order(:created_at).to_a)
    roles = roles.first(ENV["LIMIT"].to_i) if ENV["LIMIT"].present?
    why = FitScores.refusal(roles)
    abort(roles.empty? && args[:id].blank? ? "Every role offered has a current score: see fit:list." : "#{why.upcase_first}.") if why
    weighable = FitScores.weighable(roles)
    if weighable.empty?
      abort(args[:id].present? ? "#{named.call(roles.sole)} has no page of its own to read a description from." :
                                 "None of the #{WrittenFrom.counted(roles.size, 'role')} unscored has a page of its own to read a description from.")
    end

    cost = FitScores.estimate * weighable.size
    if args[:id].blank? && ENV["GO"] != "1"
      pageless = roles.size - weighable.size
      puts "#{WrittenFrom.counted(roles.size, 'role')} unscored: #{weighable.size} can be weighed (the description on record, " \
           "or read first for free)#{", #{pageless} #{pageless == 1 ? 'has' : 'have'} no page of its own to read it from" if pageless.positive?}."
      puts "Weighing them would cost about #{dollars.call(cost)} (#{dollars.call(FitScores.estimate)} a role). Run it with GO=1."
      next
    end

    puts "Backed up to #{DatabaseBackup.call}"
    describe.call(weighable)
    puts "Weighing #{weighable.one? ? named.call(weighable.first) : "#{weighable.size} roles"} with Haiku 4.5: about #{dollars.call(cost)}."
    report.call(FitScores.weigh!(weighable))
    puts "See them with fit:list, or one in full with fit:show[posting_id]."
  rescue ArgumentError, Verifier::Worker::Error => e
    abort e.message.upcase_first
  end

  desc "Roles by how well they fit your resume, best first: each one's newest score, and whether it is stale. " \
       "[MIN=70] [LIMIT=n]"
  task list: :environment do
    postings = Posting.includes(:company, :application).where(id: FitScore.select(:posting_id)).index_by(&:id)
    abort "No role is weighed yet: see fit:score." if postings.empty?

    shown = FitScores.shown(postings.keys).values
    shown = shown.select { |entry| entry.score.score >= ENV["MIN"].to_i } if ENV["MIN"].present?
    shown = shown.sort_by { |entry| [ -entry.score.score, postings[entry.score.posting_id].role_title.downcase ] }
    shown = shown.first(ENV["LIMIT"].to_i) if ENV["LIMIT"].present?
    shown.each do |entry|
      posting = postings[entry.score.posting_id]
      puts "#{entry.score.score.to_s.rjust(3)}  #{posting.id}  #{named.call(posting)} (#{posting.tracking}" \
           "#{', applied' if posting.application})#{"  stale: #{entry.stale.to_sentence} changed" if entry.stale?}"
    end
  end

  desc "A role's newest fit score in full: why, the level asked, the matches with their resume lines, the gaps, and what " \
       "it was weighed from. Usage: bin/rails \"fit:show[posting_id]\""
  task :show, [ :id ] => :environment do |_task, args|
    posting = find.call(args[:id])
    score = posting.fit_scores.includes(:llm_call, :resume, :role_description).newest_first.first or
      abort "#{named.call(posting)} isn't weighed yet: fit:score[#{posting.id}]."

    puts "#{named.call(posting)}: #{score.score} of 100"
    puts "  #{score.why}"
    puts "  Level: #{score.level}" if score.level
    puts "\nMatches"
    score.matches.each do |match|
      numbers = match["lines"].map { |line| line["line"] }
      puts "  - #{match['point']}#{" [#{'line'.pluralize(numbers.size)} #{numbers.join(', ')}]" if numbers.any?}"
    end
    puts "  none found" if score.matches.empty?
    puts "\nGaps"
    score.gaps.each { |gap| puts "  - #{gap['asks']}: #{gap['note']}" }
    puts "  none found" if score.gaps.empty?
    puts "  #{score.dropped_lines} lines it named aren't in the resume: left out" if score.dropped_lines.positive?
    call = score.llm_call
    puts "\nWeighed #{score.created_at.to_date} by #{score.writer}#{" with #{call.model} for #{dollars.call(call.cost_usd)}" if call}, from " \
         "the resume #{score.resume ? "saved #{score.resume.created_at.to_date}" : '(since deleted)'} and the role's description " \
         "#{score.role_description ? "read #{score.role_description.first_read_at.to_date}" : '(no longer on record)'}"
    stale = score.stale_for(SearchProfile.current&.resumes&.newest_first&.first, posting.role_descriptions.newest_first.first)
    puts "Stale: #{stale.to_sentence} changed since; fit:score[#{posting.id}] weighs it again." if stale.any?
  end
end
