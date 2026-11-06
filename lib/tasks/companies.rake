namespace :companies do
  # What the operator wants of a company (4b), from ENV: a list as comma-separated words.
  given = lambda do
    { "company_wants" => ENV["WANTS"], "company_avoids" => ENV["AVOIDS"], "company_stages" => ENV["STAGES"],
      "company_sizes" => ENV["SIZES"], "company_models" => ENV["MODELS"], "company_industries" => ENV["INDUSTRIES"],
      "company_excluded" => ENV["EXCLUDED"] }.compact
  end
  find = lambda do |text|
    text.to_s.strip.presence or abort 'Name the company: bin/rails "companies:review[company id or name]"'
    Company.find_by(id: text.match?(/\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/) ? text : nil) ||
      Company.find_by("lower(name) = ?", text.strip.downcase) or abort "No company #{text.inspect}: give its id or its name as on record."
  end

  desc "What you want of a company (4b), kept with the search profile; given any of WANTS=, AVOIDS= (your own words), " \
       "STAGES=, SIZES=, MODELS=, INDUSTRIES=, EXCLUDED= (comma-separated), saves those, audited as you (your words by a " \
       "hash alone); backs up first. Stages: pre_seed, seed, series_a, series_b, series_c_plus, public, private, " \
       "bootstrapped; sizes: 1-10, 11-50, 51-200, 201-500, 501-1000, 1001-5000, 5001+; models: b2b, b2c, b2b2c."
  task preferences: :environment do
    profile = SearchProfile.current or abort "Save the search profile first, on the Profile page: the company preferences are kept with it."
    if given.call.any?
      puts "Backed up to #{DatabaseBackup.call}"
      puts CompanyPreferences.save!(profile, given.call) ? "Company preferences saved." : "Nothing changed: they are as given."
    end
    said = CompanyPreferences.said(profile.reload)
    puts said.any? ? said : "No company preferences yet: give WANTS=, AVOIDS=, STAGES=, SIZES=, MODELS=, INDUSTRIES= or EXCLUDED=."
    puts "Version #{profile.company_preferences_version}: a review read against another is stale." if said.any?
  rescue ArgumentError => e
    abort e.message.upcase_first
  end

  desc "The companies reviewed against your company preferences (4b), best first, each by its newest review, a stale one " \
       "marked (MIN=70, LIMIT=); DUE=1 lists those tracked or proposed with no review against them as they are now."
  task reviews: :environment do
    profile = SearchProfile.current
    if ENV["DUE"] == "1"
      due = CompanyReviews.due(profile: profile).order(:name).to_a
      puts due.empty? ? "None due." : "#{due.size} due a review:"
      due.each { |company| puts "- #{company.name} (#{company.domain || 'no domain'}, #{Verifier::Tracking.label(company.tracking)}): #{company.id}" }
      next
    end

    newest = CompanyReview.select("DISTINCT ON (company_id) company_reviews.*").order(:company_id, created_at: :desc)
    reviews = CompanyReview.from(newest, :company_reviews).includes(:company).order(score: :desc).to_a
    reviews.select! { |review| review.score >= Integer(ENV["MIN"]) } if ENV["MIN"].present?
    reviews = reviews.first(Integer(ENV["LIMIT"])) if ENV["LIMIT"].present?
    puts reviews.empty? ? "No company reviewed yet." : "#{reviews.size} companies, best first:"
    reviews.each do |review|
      puts "#{review.score.to_s.rjust(3)}  #{review.company.name}#{' (stale: the preferences changed)' if review.stale?(profile)}  " \
           "#{CompanyReviews.said(review)}  #{review.company_id}"
    end
  rescue ArgumentError => e
    abort e.message.upcase_first
  end

  desc "One company's newest review in full: its score and why, each preference, the facts with their sources, " \
       "concerns and questions. Usage: bin/rails \"companies:review[company id or name]\""
  task :review, [ :company ] => :environment do |_task, args|
    company = find.call(args[:company])
    review = CompanyReviews.newest(company) or abort "#{company.name} has no review yet."
    puts "#{company.name}: #{review.score}#{' (stale: the preferences changed since)' if review.stale?}, by #{review.writer}, " \
         "#{review.created_at.utc.strftime('%Y-%m-%d %H:%M')} UTC"
    puts "Why: #{review.why}"
    puts "Points:", review.points.map { |point| "  #{point['verdict']}: #{point['preference']}#{" (#{point['evidence']})" if point['evidence']}" }
    shown = { "Stage" => SearchProfile::COMPANY_STAGES[review.stage], "Size" => (review.size && "#{review.size} people"),
              "Model" => SearchProfile::COMPANY_MODELS[review.business_model], "Industries" => review.industries.join(", ").presence,
              "Regions" => review.regions.join(", ").presence }.compact
    puts "Facts: #{shown.map { |name, value| "#{name} #{value}" }.join('; ')}" if shown.any?
    review.facts.each { |fact| puts "  #{fact['about']}: #{fact['said']}#{" [#{fact['sources'].join(' ')}]" if fact['sources'].any?}" }
    puts "Concerns:", review.concerns.map { |concern| "  #{concern}" } if review.concerns.any?
    puts "Questions:", review.questions.map { |question| "  #{question}" } if review.questions.any?
    puts "Sources: #{review.sources.join(' ')}" if review.sources.any?
    earlier = company.company_reviews.count - 1
    puts "#{earlier} earlier #{earlier == 1 ? 'review' : 'reviews'} kept." if earlier.positive?
  end
end
