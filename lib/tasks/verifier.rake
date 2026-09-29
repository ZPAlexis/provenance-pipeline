namespace :verifier do
  # Each run keeps its targets, results, and report under tmp/ (gitignored):
  # results name real companies from the private target list.
  run_dir = ->(name) { Rails.root.join("tmp/verifier/#{Time.current.utc.strftime('%Y%m%dT%H%M%SZ')}-#{name}") }

  build_worker = lambda do |name|
    worker = Verifier::Worker.new(run_dir: run_dir.call(name), model: ENV["MODEL"].presence)
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
end
