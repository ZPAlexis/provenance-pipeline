namespace :verifier do
  # Each run keeps its targets, results, and report under tmp/ (gitignored):
  # results name real companies from the private target list.
  run_dir = ->(name) { Verifier::Worker.dir_for(name) }

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

  desc "Find careers pages for companies not yet attempted, and record them. Backs up first. [PAGE=on_record|none] " \
       "[IDS=id,id redoes those companies] " \
       "[SLICE=brazil] [LIMIT=n] [MODEL=...]"
  task resolve: :environment do
    # PAGE splits the work: companies with a careers page on record (mostly confirmed at the first step,
    # cheap) from those without one (the whole ladder).
    # IDS redoes named companies whatever their state, e.g. after a fix; each change is audited as usual.
    scope =
      if ENV["IDS"].present?
        Company.where(id: ENV["IDS"].split(",").map(&:strip))
      else
        { nil => Company.unresolved, "on_record" => Company.unresolved.with_careers_page,
          "none" => Company.unresolved.needing_careers_page }.fetch(ENV["PAGE"].presence) do
          abort "PAGE is on_record or none."
        end
      end
    companies = select_companies.call(scope).to_a
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
      if company.kind_suggestion
        puts "  Suggested kind: #{company.kind_suggestion}. Confirm it with " \
             "bin/rails \"verifier:kind[#{company.id},#{company.kind_suggestion}]\" (or employer/recruiter/aggregator)."
      end
    end
    puts "\nbin/rails \"verifier:confirm[ID]\" makes it the watched page; bin/rails \"verifier:reject[ID]\" turns it down;"
    puts "URL=\"https://...\" REASON=\"...\" bin/rails \"verifier:set_page[ID]\" sets the right page when you know it."
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

  desc "Show one company: its resolution, watched page, recent page checks, postings, and latest writes. " \
       "Usage: bin/rails \"verifier:status[name or id]\""
  task :status, [ :company ] => :environment do |_task, args|
    company = Verifier::Status.find(args[:company]) or
      abort "No single company matches #{args[:company].inspect}. Try its exact name or its id."
    puts Verifier::Status.lines(company)
  end

  desc "Say what kind of company it is: employer, recruiter, or aggregator. Audited as the operator. " \
       "Usage: [REASON=\"...\"] bin/rails \"verifier:kind[company_id,recruiter]\""
  task :kind, [ :id, :kind ] => :environment do |_task, args|
    company = Company.find_by(id: args[:id]) or abort "No company #{args[:id].inspect}."
    Verifier::Candidates.set_kind!(company, args[:kind].to_s.strip, reasoning: ENV["REASON"])
    puts "#{company.name}: #{company.kind}"
    if company.resolution_status == "candidate"
      verb = company.kind == "aggregator" ? "reject" : "confirm"
      puts "Its candidate page is still waiting: bin/rails \"verifier:#{verb}[#{company.id}]\" " \
           "(an aggregator's page of other companies' postings is not its careers page)."
    end
  rescue ArgumentError => e
    abort e.message
  end

  desc "Set a company's careers page by hand, whatever its state. Audited as the operator. " \
       "Usage: URL=\"https://...\" REASON=\"...\" bin/rails \"verifier:set_page[company_id]\""
  task :set_page, [ :id ] => :environment do |_task, args|
    company = Company.find_by(id: args[:id]) or abort "No company #{args[:id].inspect}."
    url = ENV["URL"].presence or abort "Give the page in URL=\"https://...\" (an address can hold commas)."
    reason = ENV["REASON"].presence or abort "Say how you know it is the page in REASON=\"...\": it becomes the audit reasoning."

    # A human correction cannot be regenerated from source, so it is backed up like any batch that writes.
    puts "Backed up to #{DatabaseBackup.call}"
    before = company.careers_page_url || company.resolution_candidate_url
    Verifier::Candidates.set_page!(company, url, reasoning: reason)
    puts "#{company.name}: watching #{company.careers_page_url} (#{company.ats_type})#{" instead of #{before}" if before && before != url}"
  rescue ArgumentError => e
    abort e.message
  end

  # What a check now did, after adding by URL: the answer for a role, and what was read.
  report_check = lambda do |outcome, title|
    answer = { "verified_live" => "STILL LISTED", "not_found" => "NO LONGER LISTED" }.fetch(outcome.answer, nil)
    puts "\n#{title}#{": #{answer}" if answer}#{' (stopped)' unless outcome.finished?}"
    puts "  #{outcome.summary}"
    puts format("  Cost: est. $%.4f   (details: %s)", outcome.cost_usd, outcome.run_dir)
  end

  desc "Add a company by its domain, careers page, or ATS board, then find its careers page and read it. " \
       "Audited as you; backs up first. Usage: URL=\"acme.com\" bin/rails verifier:add [NAME=\"Acme\"]"
  task add: :environment do
    url = ENV["URL"].presence or abort "Give its domain, careers page, or ATS board in URL=\"...\"."
    Verifier::Capture.parse(url) # a link refused is refused before anything is backed up or written
    puts "Backed up to #{DatabaseBackup.call}"
    added = Verifier::Capture.company!(url, name: ENV["NAME"])
    company = added.company
    puts added.note
    next if company.resolution_status == "resolved"
    if (why = Verifier::CheckNow.refusal(company))
      abort why
    end

    puts format("Finding its careers page and reading it: at most about $%.2f.", Verifier::CheckNow.ceiling(company))
    outcome = Verifier::CheckNow.company(company, worker: build_worker.call("verify"), finder: build_worker.call("resolve"))
    report_check.call(outcome, company.name)
  rescue ArgumentError, ActiveRecord::RecordInvalid => e
    abort e.message
  end

  desc "Add a role by its own page at the employer (or its ATS posting), tracked, then check it. Without TITLE its " \
       "page names it. Audited as you; backs up first. Usage: URL=\"https://...\" bin/rails verifier:add_role " \
       "[TITLE=\"...\"] [LOCATION=\"...\"] [SOURCE=\"where you found it\"] [COMPANY=\"name, if new\"]"
  task add_role: :environment do
    url = ENV["URL"].presence or abort "Give the role's own page in URL=\"...\"."
    Verifier::Capture.parse(url, role: true)
    puts "Backed up to #{DatabaseBackup.call}"
    placed = Verifier::Capture.role!(link: url, title: ENV["TITLE"], location: ENV["LOCATION"], source: ENV["SOURCE"],
                                     company_name: ENV["COMPANY"])
    posting = placed.posting
    puts placed.note
    if (why = Verifier::CheckNow.refusal(posting))
      abort why
    end

    ceiling = Verifier::CheckNow.ceiling(posting)
    puts format("Checking it: its own page first; at most about $%.2f.", ceiling) if ceiling.positive?
    outcome = Verifier::CheckNow.role(posting, worker: build_worker.call("check"), finder: build_worker.call("resolve"))
    report_check.call(outcome, "#{posting.company.name} / #{posting.reload.role_title}")
  rescue ArgumentError, ActiveRecord::RecordInvalid => e
    abort e.message
  end

  desc "Rename a company. Audited as you. Usage: NAME=\"ArcelorMittal Brasil\" bin/rails \"verifier:rename[company_id]\""
  task :rename, [ :id ] => :environment do |_task, args|
    company = Company.find_by(id: args[:id]) or abort "No company #{args[:id].inspect}."
    name = ENV["NAME"].to_s.strip.presence or abort "Give the name in NAME=\"...\"."
    before = company.name
    ApplicationRecord.transaction do
      company.update!(name: name)
      AuditEvent.record_write!(company, actor: AuditEvent::OPERATOR, reasoning: "Renamed by hand.")
    end
    puts "#{before} is now #{company.name}."
  rescue ActiveRecord::RecordInvalid => e
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
      read = ->(paths) { paths.flat_map { |dir| Verifier::Worker.read_results(dir.join("results.jsonl")) } }
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

  desc "Test B: verify labeled postings against their company's watched page and compare with the label. Read-only. " \
       "REPLAY=1 matches the listings stored by earlier checks (no page fetched); FRESH=1 reads every watched page " \
       "now (costs API credit). RESULTS=dir[,dir] re-scores saved runs (no API cost; a later run wins for a " \
       "company). NO_LLM=1 leaves near-misses undecided. [COMPANY=name] [IDS=company_id,...] [MODEL=...]"
  task test_b: :environment do
    # Reading every watched page costs API credit, so it is asked for by name, never a default.
    replay, rescore = ENV["REPLAY"].present?, ENV["RESULTS"].present?
    unless replay || rescore || ENV["FRESH"].present?
      abort "Say REPLAY=1 (stored listings, no API cost), RESULTS=dir (re-score a saved run, no API cost), " \
            "or FRESH=1 (reads every watched page now)."
    end

    postings = Posting.includes(:company)
    postings = postings.joins(:company).where("lower(companies.name) = ?", ENV["COMPANY"].strip.downcase) if ENV["COMPANY"].present?
    postings = postings.where(company_id: ENV["IDS"].split(",").map(&:strip)) if ENV["IDS"].present?
    test = Verifier::TestB.new(postings)

    if rescore
      # Saved runs scored again, e.g. after recording hand checks: nothing is read, nothing is spent.
      dirs = ENV["RESULTS"].split(",").map { |dir| Pathname.new(dir.strip) }
      results = dirs.flat_map { |dir| Verifier::Worker.read_results(dir.join("results.jsonl")) }
                    .index_by { |result| result["target_id"] }.values
      abort "No results in #{dirs.join(', ')}." if results.empty?
      mode = "re-scored"
      run = Verifier::Worker::Run.new(dir: run_dir.call("test_b_rescore").tap { |dir| FileUtils.mkdir_p(dir) },
                                      results: results, stopped: nil)
      puts "Test B (re-scored): #{results.size} companies' saved reads from #{dirs.map(&:basename).join(', ')}\n\n"
    else
      targets = replay ? test.replay_targets : test.verify_targets
      abort "No labeled postings at a company with a watched page#{' and a stored check of it' if replay}." if targets.empty?

      flags = ENV["NO_LLM"].present? ? [ "--no-llm" ] : []
      mode = replay ? "replay" : "fresh"
      puts "Test B (#{mode}): #{targets.sum { |t| t[:postings].size }} postings at #{targets.size} companies, " \
           "#{flags.any? ? 'no LLM' : "near-misses judged by #{ENV['MODEL'].presence || 'the default model'}"}\n\n"
      run = build_worker.call("test_b_#{mode}").run(targets, command: replay ? "match" : "verify", flags: flags)
    end
    report = test.evaluate(run.results)

    puts format("\n%-24s %-34s %-14s %-14s %-8s %s", "company", "posting", "label", "verdict", "method", "result")
    report.cases.sort_by { |c| [ c.measured? ? 0 : 1, c.company ] }.each do |c|
      result =
        if c.false_live? then "FALSE LIVE: hand-check whether the role is really there"
        elsif c.agrees_by_hand? then "agrees (your hand check: the label was wrong or stale)"
        elsif c.agrees? then "agrees"
        elsif c.measured? then "disagrees: hand-check whether the label went stale"
        else "not measured: #{c.why_unmeasured}"
        end
      puts format("%-24s %-34s %-14s %-14s %-8s %s", c.company.truncate(24), c.title.truncate(34), c.label,
                  c.verdict || "-", c.result&.dig("method") || "-", result)
    end

    if report.disagreements.any?
      puts "\nDisagreements, with the verifier's reasoning (record what you find with verifier:hand_check):"
      report.disagreements.each do |c|
        puts "  #{c.company} / #{c.title} (#{c.label} -> #{c.verdict}): #{c.result['reasoning']}"
        puts "      posting #{c.posting_id}"
      end
    end
    puts "\nBy method (method, agrees): #{report.by_method.sort_by { |key, _| key.map(&:to_s) }.to_h}"
    puts "Agreement: #{report.agreeing}/#{report.measured.size} measured " \
         "(#{(report.share * 100).round}%, #{(Verifier::TestB::REQUIRED_AGREEMENT * 100).round}% required); " \
         "not measured: #{report.unmeasured.size}"
    puts "Labeled negatives reported live: #{report.false_lives.size} (none allowed unless a hand-check confirms the role)"
    puts "Cost: #{report.tokens} tokens, est. $#{format('%.4f', report.cost_usd)}"
    puts "\nTEST B (#{mode}): #{report.passed? ? 'PASS' : 'FAIL'}   (details: #{run.dir})"

    run.dir.join("report.json").write(JSON.pretty_generate(
      passed: report.passed?, agreeing: report.agreeing, measured: report.measured.size, cases: report.cases.size,
      false_lives: report.false_lives.size, by_method: report.by_method.transform_keys { |key| key.join("/") },
      cost_usd: report.cost_usd, stopped: run.stopped
    ))
    report_stop.call(run)
  end

  desc "Verify postings against their company's watched page and record the verdicts. Shows the plan and its " \
       "estimated cost; runs only with GO=1, backing up first. RESULTS=dir records a passing Test B run's reads " \
       "instead of reading those pages again. [COMPANY=name] [LIMIT=n] [MODEL=...] [NO_LLM=1]"
  task verify: :environment do
    companies = select_companies.call(Company.watched.where(id: Posting.not_dismissed.select(:company_id))).to_a
    abort "No resolved company has postings to verify." if companies.empty?

    targets = companies.map { |company| Verifier::Targets.verify(company) }

    # Pages already read (a passing fresh Test B run): recorded as they are, never paid for twice.
    saved = [] # [run_id, result]: each saved read recorded under the run that made it
    if ENV["RESULTS"].present?
      wanted = targets.to_h { |t| [ t[:id], t ] }
      ENV["RESULTS"].split(",").map { |dir| Pathname.new(dir.strip) }.each do |dir|
        file = dir.join("results.jsonl")
        abort "No results in #{dir}." unless file.exist?
        Verifier::Worker.read_results(file).each do |result|
          next unless result["kind"] == "verification" && wanted.key?(result["target_id"])

          saved.reject! { |_, earlier| earlier["target_id"] == result["target_id"] } # a later run wins
          saved << [ dir.basename.to_s, result ]
        end
        puts "Reusing reads from #{dir.basename} (#{((Time.current - file.mtime) / 3600).round(1)} hours old)."
      end
      puts "#{saved.size} companies' saved reads are recorded as they are, not read again."
      reused = saved.to_set { |_, result| result["target_id"] }
      targets = targets.reject { |t| reused.include?(t[:id]) }
    end

    # A ceiling from the record: what each page cost when last read in full. A company read
    # through its confirmed board costs nothing; a page whose roles are unchanged reuses its
    # earlier read for nothing; one never verified is priced at the average page read.
    per_page = LlmCall.where(purpose: "extract").average(:cost_usd).to_f
    by_id = companies.index_by(&:id)
    via_board = targets.count { |t| t[:board] }
    reusable = targets.count { |t| !t[:board] && t[:previous].any? }
    ceiling = targets.reject { |t| t[:board] }.sum { |t| Verifier::Targets.full_read_cost(by_id[t[:id]]) || per_page }
    puts "Plan: verify #{targets.sum { |t| t[:postings].size }} postings at #{targets.size} companies' watched pages."
    puts "  #{via_board} read through a confirmed board (free); #{reusable} have earlier reads to reuse where " \
         "their role links are unchanged (free when they are, a full read every 14 days)."
    puts format("Estimated cost: at most $%.2f, what these pages cost when last read in full; less for every page " \
                "whose roles are unchanged, plus about a cent for near-miss checks.", ceiling)
    next puts("\nNothing run. Run it with GO=1.") unless ENV["GO"].present?

    # From here on, verdicts are written: back up first.
    puts "Backed up to #{DatabaseBackup.call}\n\n"
    flags = ENV["NO_LLM"].present? ? [ "--no-llm" ] : []
    tally = Hash.new(0)
    invalid = []
    record = lambda do |results, run_id|
      ingest = Verifier::Ingest.new(run_id: run_id)
      results.each do |result|
        ingest.verification(result).each { |what, count| tally[what] += count }
      rescue Verifier::Ingest::InvalidResult => e
        invalid << e.message
      end
    end

    saved.group_by(&:first).each { |run_id, pairs| record.call(pairs.map(&:last), run_id) }
    run = build_worker.call("verify").run(targets, command: "verify", flags: flags) if targets.any?
    record.call(run.results, run.id) if run

    recorded = saved.size + (run ? run.results.size : 0) - invalid.size
    puts "\nRecorded #{recorded}/#{saved.size + targets.size} companies: " \
         "#{tally[:written]} verdicts written, #{tally[:unchanged]} confirmed unchanged, " \
         "#{tally[:inconclusive]} inconclusive (no verdict)"
    invalid.each { |message| puts "  NOT RECORDED, breaks the result contract: #{message}" }
    cost = Array(run&.results).sum do |r|
      Array(r["checks"]).sum { |check| check.dig("llm", "cost_usd").to_f } + r.dig("match_llm", "cost_usd").to_f
    end
    puts "Cost of the pages read now: est. $#{format('%.4f', cost)}#{"   (details: #{run.dir})" if run}"
    report_stop.call(run) if run

    # The lists just read, weighed against the search profile: suggestions brought up to date, at no cost.
    if SearchProfile.current
      refresh = Verifier::Suggestions.refresh!(companies)
      puts refresh.summary
      refresh.problems.each { |problem| puts "  #{problem}" }
    end
  end

  desc "Look for a free ATS board listing the same roles as each page the LLM had to read, and read through it from " \
       "then on. Never calls the LLM; backs up first. [COMPANY=name] [LIMIT=n]"
  task find_boards: :environment do
    targets = select_companies.call(Company.watched).filter_map { |company| Verifier::Targets.board(company) }
    abort "No company's page was read by the LLM since its board was last looked for." if targets.empty?

    puts "Looking for boards for #{targets.size} companies whose pages the LLM read (no API cost)."
    puts "Backed up to #{DatabaseBackup.call}\n\n"
    run = build_worker.call("find_boards").run(targets, command: "boards")
    ingest = Verifier::Ingest.new(run_id: run.id)
    names = Company.where(id: targets.pluck(:id)).pluck(:id, :name).to_h
    tally = Hash.new(0)
    run.results.each do |result|
      tally[ingest.board(result)] += 1
      puts "  #{names[result['target_id']]}: #{result['outcome']}, #{result['evidence'] || result['reason']}"
    rescue Verifier::Ingest::InvalidResult => e
      puts "  NOT RECORDED, breaks the result contract: #{e.message}"
    end
    puts "\n#{tally['adopted']} boards read in place of their pages from now on; #{tally['rejected']} found but not " \
         "listing the same roles; #{tally['none']} companies with no board found.   (details: #{run.dir})"
    report_stop.call(run)
  end

  desc "Check one role now: its own page at the employer first, then its company's careers page. Records the " \
       "verdict like any check; backs up first. Usage: bin/rails \"verifier:check[posting_id]\" [MODEL=...]"
  task :check, [ :id ] => :environment do |_task, args|
    posting = Posting.includes(:company).find_by(id: args[:id]) or
      abort "No posting #{args[:id].inspect}. Its id is in verifier:status."
    if (why = Verifier::CheckNow.refusal(posting))
      abort why
    end

    puts "Checking #{posting.company.name} / #{posting.role_title}: " \
         "#{posting.job_url ? "its own page first, #{posting.job_url}" : 'no page of its own on record'}."
    ceiling = Verifier::CheckNow.ceiling(posting)
    puts format("At most about $%.2f, if its careers page has changed and must be read again.", ceiling) if ceiling.positive?
    puts "Backed up to #{DatabaseBackup.call}"
    outcome = Verifier::CheckNow.role(posting, worker: build_worker.call("check"))

    answer = { "verified_live" => "STILL LISTED", "not_found" => "NO LONGER LISTED" }.fetch(outcome.answer, "COULDN'T CONFIRM")
    puts "\n#{posting.role_title}: #{outcome.finished? ? answer : 'STOPPED'}"
    puts "  #{outcome.summary}"
    puts format("  Cost: est. $%.4f   (details: %s)", outcome.cost_usd, outcome.run_dir)
  rescue Verifier::Ingest::InvalidResult => e
    abort "NOT RECORDED, breaks the result contract: #{e.message}"
  end

  desc "Track a role: on your watch list, checked by every run and by verifier:check. Audited as you. " \
       "Usage: NOTE=\"why\" bin/rails \"verifier:track[posting_id]\""
  task :track, [ :id ] => :environment do |_task, args|
    posting = Posting.find_by(id: args[:id]) or abort "No posting #{args[:id].inspect}. Its id is in verifier:status."
    puts "Backed up to #{DatabaseBackup.call}"
    Verifier::Tracking.track!(posting, note: ENV["NOTE"])
    puts "#{posting.company.name} / #{posting.role_title}: tracked"
  rescue ArgumentError, ActiveRecord::RecordInvalid => e
    abort e.message
  end

  desc "Dismiss a role for good: never checked or suggested again (track it again to undo). Audited as you. " \
       "Usage: NOTE=\"why\" bin/rails \"verifier:dismiss[posting_id]\""
  task :dismiss, [ :id ] => :environment do |_task, args|
    posting = Posting.find_by(id: args[:id]) or abort "No posting #{args[:id].inspect}. Its id is in verifier:status."
    puts "Backed up to #{DatabaseBackup.call}"
    Verifier::Tracking.dismiss!(posting, note: ENV["NOTE"])
    puts "#{posting.company.name} / #{posting.role_title}: dismissed"
  rescue ArgumentError, ActiveRecord::RecordInvalid => e
    abort e.message
  end

  desc "Fill in each posting's own page at the employer from the listing it already matched. No API cost; " \
       "backs up first."
  task backfill_job_urls: :environment do
    puts "Backed up to #{DatabaseBackup.call}"
    learned = Verifier::JobUrls.backfill!
    remaining = Posting.not_dismissed.where(job_url: nil).count
    puts "#{learned} postings learned their own page; #{remaining} have none yet " \
         "(never matched live, or the listing they matched had no link)."
  end

  desc "Bring suggestions up to date: each watched company's latest list weighed against the saved search profile, " \
       "written as agent:suggester. No API cost; backs up first (at most once a day). PREVIEW=1 shows what it " \
       "would suggest and writes nothing. [COMPANY=name] [LIMIT=n]"
  task suggest: :environment do
    profile = SearchProfile.current or abort "No search profile is saved yet: save one on the Profile page."
    puts "Profile: #{profile.titles.join(', ')}#{" in #{profile.places.join(', ')}" if profile.places.any?}"

    if ENV["PREVIEW"].present?
      preview = Verifier::Suggestions.preview(profile)
      preview.new_roles.each { |fit| puts "  + #{fit.company.name} / #{fit.listing['title']} (#{fit.listing['location']})" }
      puts "Would suggest #{preview.new_roles.size} new roles from #{preview.weighed} weighed at #{preview.companies} " \
           "companies; #{preview.on_record.size} more fit but are on record, #{preview.ruled_out.size} ruled out. Nothing written."
      preview.problems.each { |problem| puts "  Not weighed: #{problem}" }
      next
    end

    refresh = Verifier::Suggestions.refresh!(select_companies.call(Company.watched), profile: profile,
                                             worker: Verifier::Worker.new(run_dir: run_dir.call("suggest")))
    puts refresh.summary
    puts "   (details: tmp/verifier/#{refresh.run_id})" if refresh.run_id
  end

  desc "Record a check you made yourself at the employer's page as a posting's verdict, audited as you. " \
       "Usage: VERDICT=not_found NOTE=\"what you saw\" [ROLES=n] [WORK_MODE=remote] " \
       "bin/rails \"verifier:hand_check[posting_id]\""
  task :hand_check, [ :id ] => :environment do |_task, args|
    posting = Posting.find_by(id: args[:id]) or abort "No posting #{args[:id].inspect}. Its id is in verifier:status."
    roles = ENV["ROLES"].presence && Integer(ENV["ROLES"], exception: false)
    abort "ROLES must be a whole number." if ENV["ROLES"].present? && roles.nil?

    # A human check cannot be regenerated from source, so it is backed up like any batch that writes.
    puts "Backed up to #{DatabaseBackup.call}"
    Verifier::HandCheck.record!(posting, verdict: ENV["VERDICT"].to_s.strip, note: ENV["NOTE"], roles: roles,
                                         work_mode: ENV["WORK_MODE"].presence)
    puts "#{posting.company.name} / #{posting.role_title}: #{posting.verification_state}, checked by hand"
  rescue ArgumentError, ActiveRecord::RecordInvalid => e
    abort e.message
  end

  desc "Undo the verifier's latest verdict on a posting, restoring what it replaced. Audited as you. " \
       "Usage: REASON=\"why the verdict was wrong\" bin/rails \"verifier:undo_verdict[posting_id]\""
  task :undo_verdict, [ :id ] => :environment do |_task, args|
    posting = Posting.find_by(id: args[:id]) or abort "No posting #{args[:id].inspect}. Its id is in verifier:status."

    # A correction cannot be regenerated from source, so it is backed up like any batch that writes.
    puts "Backed up to #{DatabaseBackup.call}"
    Verifier::HandCheck.undo_verdict!(posting, reasoning: ENV["REASON"])
    puts "#{posting.company.name} / #{posting.role_title}: back to #{posting.verification_state}"
  rescue ArgumentError, ActiveRecord::RecordInvalid => e
    abort e.message
  end
end
