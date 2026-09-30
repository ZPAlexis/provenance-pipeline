namespace :verifier do
  # Each run keeps its targets, results, and report under tmp/ (gitignored):
  # results name real companies from the private target list.
  run_dir = ->(name) { Rails.root.join("tmp/verifier/#{Time.current.utc.strftime('%Y%m%dT%H%M%SZ')}-#{name}") }

  # A name for a new timestamped run directory, or a directory to use as is.
  build_worker = lambda do |name_or_dir|
    dir = name_or_dir.is_a?(Pathname) ? name_or_dir : run_dir.call(name_or_dir)
    worker = Verifier::Worker.new(run_dir: dir, model: ENV["MODEL"].presence)
    unless worker.credential?
      puts "Note: no API key in #{Verifier::Worker::CREDENTIAL_FILE}. Pages on a known ATS still work;"
      puts "any page that needs the LLM will stop the run."
    end
    worker
  end

  report_stop = ->(run) { puts "\nSTOPPED EARLY: #{run.stopped}. Results so far are kept in #{run.dir}." if run.stopped }

  desc "Test A: extract listings from every careers page with a recorded roles count. [MODEL=claude-haiku-4-5]"
  task test_a: :environment do
    test = Verifier::TestA.new
    abort "No companies with a careers page to test." if test.targets.empty?

    puts "Test A: #{test.targets.size} careers pages, model #{ENV['MODEL'].presence || 'default'}\n\n"
    run = build_worker.call("test_a").run(test.targets)
    report = test.evaluate(run.results)

    puts format("\n%-28s %8s %9s %8s %6s  %-22s %s", "company", "recorded", "extracted", "distinct", "stated", "method", "result")
    report.pages.each do |page|
      verdict =
        if page.result.nil? then "not checked"
        elsif page.blocked? then "not measured: #{page.result['reason']}, and no ATS board found"
        elsif !page.yielded? then "FAIL: #{page.result['reason'] || 'no listings'}#{' (page says no openings)' if page.says_no_openings?}"
        elsif page.comparable? && !page.within_tolerance? then "investigate: outside tolerance"
        else "ok#{' (recorded 0: the known parse failure, now read)' if page.known_failure?}"
        end
      if page.ats_fallback?
        why = page.result["reason"].delete_suffix("_ats_fallback").delete_prefix("robots_")
        verdict += " [page not read: robots.txt #{why}; listings from the company's ATS board]"
      end
      puts format("%-28s %8s %9s %8s %6s  %-22s %s", page.company.truncate(28), page.recorded.inspect,
                  page.extracted.inspect, page.distinct_titles.inspect, page.stated_total.inspect,
                  page.result&.dig("method") || "-", verdict)
    end

    puts "\nPages yielding listings: #{report.yielding}/#{report.measured.size} measured (all required)"
    if report.blocked.any?
      puts "Not measured (robots.txt, no ATS board found): #{report.blocked.map(&:company).join(', ')}"
    end
    puts "Counts within tolerance: #{report.agreeing}/#{report.comparable.size} " \
         "(#{(report.agreement * 100).round}%, #{(Verifier::TestA::REQUIRED_AGREEMENT * 100).round}% required)"
    report.known_failures.each do |page|
      puts "Known parse failure #{page.company}: #{page.yielded? ? "now yields #{page.extracted} listings" : 'still yields none'}"
    end
    puts "Cost: #{report.tokens} tokens, est. $#{format('%.4f', report.cost_usd)}"
    puts "\nTEST A: #{report.passed? ? 'PASS' : 'FAIL'}   (details: #{run.dir})"

    run.dir.join("report.json").write(JSON.pretty_generate(
      passed: report.passed?, yielding: report.yielding, measured: report.measured.size, pages: report.pages.size,
      blocked: report.blocked.size, agreeing: report.agreeing, comparable: report.comparable.size,
      cost_usd: report.cost_usd, stopped: run.stopped
    ))
    report_stop.call(run)
  end

  desc "Check one careers page and list what it shows. Usage: rails \"verifier:extract[https://...]\" [MODEL=...]"
  task :extract, [ :url ] => :environment do |_task, args|
    url = args[:url] or abort 'Usage: bin/rails "verifier:extract[https://example.com/careers]"'

    # Domain and name let the worker find the company's ATS board if robots.txt keeps it off the page.
    company = Company.find_by(careers_page_url: url)
    domain = company&.domain || URI.parse(url).host
    run = build_worker.call("extract").run([ { id: "adhoc", url: url, label: url, domain: domain, name: company&.name } ])
    result = run.results.first or abort "No result."

    puts "\n#{result['outcome']}#{" (#{result['reason']})" if result['reason']} via #{result['method'] || '-'}"
    Array(result["listings"]).each { |listing| puts "  - #{listing['title']} [#{listing['work_mode']}] #{listing['location']}" }
    puts "#{result['listing_count'].inspect} listings. #{result['notes']}"
    puts "Cost: est. $#{format('%.4f', result.dig('llm', 'cost_usd').to_f)}" if result["llm"]
    report_stop.call(run)
  end

  # Companies to work on: SLICE keeps those with a posting in that source slice,
  # COMPANY names one company, and LIMIT caps how many, so a run's cost stays a choice.
  select_companies = lambda do |scope|
    scope = scope.where(id: Posting.from_slice(ENV["SLICE"]).select(:company_id)) if ENV["SLICE"].present?
    scope = scope.where("lower(name) = ?", ENV["COMPANY"].strip.downcase) if ENV["COMPANY"].present?
    scope = scope.order(:name)
    ENV["LIMIT"].present? ? scope.limit(Integer(ENV["LIMIT"])) : scope
  end

  money = ->(results) { results.sum { |r| Array(r["checks"]).sum { |check| check.dig("llm", "cost_usd").to_f } } }

  desc "Find careers pages for companies not yet attempted, and record them. Backs up first. " \
       "[SLICE=brazil] [LIMIT=n] [MODEL=...]"
  task resolve: :environment do
    companies = select_companies.call(Company.unresolved).to_a
    abort "No companies to resolve." if companies.empty?

    # From here on the database holds writes that cannot be regenerated from source.
    puts "Backed up to #{DatabaseBackup.call}"
    anonymised = Verifier::Resolution.mark_anonymised!(companies)
    puts "Marked #{anonymised} anonymised compan#{anonymised == 1 ? 'y' : 'ies'} as not resolvable." if anonymised.positive?
    targets = Verifier::Resolution.targets(companies)
    next puts("Nothing left to resolve.") if targets.empty?

    puts "Resolving #{targets.size} companies, model #{ENV['MODEL'].presence || 'default'}\n\n"
    run = build_worker.call("resolve").run(targets, command: "resolve")

    ingest = Verifier::Ingest.new(run_id: run.id)
    outcomes = Hash.new(0)
    invalid = []
    run.results.each do |result|
      outcomes[ingest.resolution(result)] += 1
    rescue Verifier::Ingest::InvalidResult => e
      invalid << e.message
    end

    puts "\nRecorded #{run.results.size - invalid.size}/#{targets.size}: #{outcomes.sort.to_h}"
    puts "Candidates waiting for you: #{Verifier::Candidates.pending.count} (bin/rails verifier:candidates)"
    invalid.each { |message| puts "  NOT RECORDED, breaks the result contract: #{message}" }
    puts "Cost: est. $#{format('%.4f', money.call(run.results))}   (details: #{run.dir})"
    report_stop.call(run)
  end

  desc "List low-confidence careers pages waiting for a human to confirm or reject"
  task candidates: :environment do
    pending = Verifier::Candidates.pending
    abort "No candidates waiting." if pending.empty?

    pending.each do |company|
      evidence = company.audit_events.where(actor: Verifier::Ingest::ACTOR).order(:occurred_at).last&.reasoning
      puts "#{company.id}  #{company.name} (#{company.domain || 'no domain'})"
      puts "  #{company.resolution_candidate_url}  [#{company.resolution_method}]"
      puts "  #{evidence}" if evidence
    end
    puts "\nbin/rails \"verifier:confirm[ID]\" makes it the watched page; bin/rails \"verifier:reject[ID]\" turns it down."
  end

  desc "Confirm a candidate careers page by hand. Usage: bin/rails \"verifier:confirm[company_id]\""
  task :confirm, [ :id ] => :environment do |_task, args|
    company = Company.find_by(id: args[:id]) or abort "No company #{args[:id].inspect}."
    Verifier::Candidates.confirm!(company)
    puts "#{company.name}: watching #{company.careers_page_url}"
  rescue Verifier::Candidates::NotACandidate => e
    abort e.message
  end

  desc "Reject a candidate careers page by hand. Usage: bin/rails \"verifier:reject[company_id]\""
  task :reject, [ :id ] => :environment do |_task, args|
    company = Company.find_by(id: args[:id]) or abort "No company #{args[:id].inspect}."
    Verifier::Candidates.reject!(company)
    puts "#{company.name}: candidate rejected"
  rescue Verifier::Candidates::NotACandidate => e
    abort e.message
  end

  print_resolution_report = lambda do |report, dir|
    puts format("\n%-28s %-10s %-14s %-7s %s", "company", "outcome", "method", "conf", "result")
    report.cases.each do |c|
      verdict =
        if c.result.nil? then "not checked"
        elsif !c.measured? then "not measured: #{c.result['failure'] || 'known page unreadable'}"
        elsif c.correct? then "correct (#{c.correct_because})"
        elsif c.wrong? then "WRONG at #{c.result['confidence']}: #{c.found_url}"
        else "missed#{": #{c.result['failure']}" if c.result['failure']}#{" (answered #{c.found_url})" if c.found_url}"
        end
      puts format("%-28s %-10s %-14s %-7s %s", c.company.truncate(28), c.outcome || "-", c.result&.dig("method") || "-",
                  c.result&.dig("confidence") || "-", verdict)
    end

    puts "\nBy outcome/method/confidence: #{report.by_method.sort_by { |key, _| key.map(&:to_s) }.map { |key, n| "#{key.compact.join('/')}=#{n}" }.join(', ')}"
    puts "Correct: #{report.correct}/#{report.measured.size} measured (#{(report.share * 100).round}%, " \
         "#{(Verifier::ResolutionTest::REQUIRED_CORRECT * 100).round}% required); not measured: #{report.unmeasured.size}"
    puts "Wrong at high or medium confidence: #{report.wrong.size} (none allowed)"
    puts "Cost: #{report.tokens} tokens, est. $#{format('%.4f', report.cost_usd)}"
    puts "\nRESOLUTION TEST: #{report.passed? ? 'PASS' : 'FAIL'}   (details: #{dir})"

    dir.join("report.json").write(JSON.pretty_generate(
      passed: report.passed?, correct: report.correct, measured: report.measured.size, companies: report.cases.size,
      wrong: report.wrong.size, by_method: report.by_method.transform_keys { |key| key.compact.join("/") },
      cost_usd: report.cost_usd
    ))
  end

  desc "Resolution test: hide known careers pages and find them again from each company's domain. Read-only. " \
       "[SLICE=brazil] [COMPANY=name] [LIMIT=n] [MODEL=...]. Re-score saved runs, no API calls: " \
       "RESULTS=dir[,dir] (a later run wins for a company it covers)"
  task test_resolution: :environment do
    if ENV["RESULTS"].present?
      # Each run's known-page checks sit in its "-known" sibling directory; KNOWN= names them for older runs.
      dirs = ENV["RESULTS"].split(",").map { |dir| Pathname.new(dir.strip) }
      known_dirs = ENV["KNOWN"].present? ? ENV["KNOWN"].split(",").map { |dir| Pathname.new(dir.strip) } : dirs.map { |dir| Pathname.new("#{dir}-known") }
      read = ->(paths) { paths.map { |dir| dir.join("results.jsonl") }.select(&:exist?).flat_map { |file| file.readlines.map { |line| JSON.parse(line) } } }
      resolutions = read.call(dirs).index_by { |result| result["target_id"] }.values
      known = read.call(known_dirs).index_by { |result| result["target_id"] }.values
      abort "No results in #{dirs.join(', ')}." if resolutions.empty?

      companies = select_companies.call(Company.with_careers_page.where(id: resolutions.map { |result| result["target_id"] }))
      test = Verifier::ResolutionTest.new(companies.to_a)
      puts "Re-scoring #{resolutions.size} saved resolutions from #{dirs.map(&:basename).join(', ')} (no API calls)"
      dir = run_dir.call("test_resolution_rescore").tap { |path| FileUtils.mkdir_p(path) }
      print_resolution_report.call(test.evaluate(resolutions, known), dir)
      next
    end

    test = Verifier::ResolutionTest.new(select_companies.call(Company.with_careers_page).to_a)
    abort "No companies with a careers page to test." if test.targets.empty?

    puts "Resolution test: #{test.targets.size} companies, known pages hidden, model #{ENV['MODEL'].presence || 'default'}\n\n"
    run = build_worker.call("test_resolution").run(test.targets, command: "resolve")
    known_targets = test.known_page_targets(run.results)
    known = []
    if known_targets.any? && !run.stopped
      puts "\nChecking #{known_targets.size} known pages that resolution answered differently\n\n"
      known = build_worker.call(Pathname.new("#{run.dir}-known")).run(known_targets).results
    end

    print_resolution_report.call(test.evaluate(run.results, known), run.dir)
    report_stop.call(run)
  end
end
