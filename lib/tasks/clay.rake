namespace :clay do
  desc "Import Clay CSV exports. Usage: rails clay:import[path/to/dir_or_file]"
  task :import, [ :path ] => :environment do |_t, args|
    path = args[:path] or abort "Usage: rails clay:import[path/to/dir_or_file]"
    pathname = Pathname.new(path)
    abort "Not found: #{path}" unless pathname.exist?

    results =
      if pathname.directory?
        ClayImporter.import_dir(pathname)
      else
        [ [ pathname.basename.to_s, ClayImporter.call(pathname) ] ]
      end

    puts "\n--- Import summary ---"
    results.each do |filename, result|
      puts format("%-44s %s", filename, result)
      result.errors.first(5).each { |e| puts "    row #{e[:row]}: #{e[:error]}" }
    end

    puts "\nCompanies: #{Company.count}   Postings: #{Posting.count}   Audit events: #{AuditEvent.count}"
  end

  desc "Summarize imported data — counts by slice, verification state, and work mode"
  task summary: :environment do
    puts "\nPostings by source slice:"
    Posting.group(:source_slice).order(count_all: :desc).count.each { |k, v| puts format("  %-10s %d", k || "(none)", v) }

    puts "\nPostings by verification state:"
    Posting.group(:verification_state).order(count_all: :desc).count.each { |k, v| puts format("  %-16s %d", k, v) }

    puts "\nPostings by work mode:"
    Posting.group(:work_mode).order(count_all: :desc).count.each { |k, v| puts format("  %-10s %d", k || "(unset)", v) }

    suspect = Posting.suspect_negatives.count
    credible = Posting.credible_negatives.count
    puts "\nNegative verdicts: #{credible} credible, #{suspect} suspect (likely parse failures)"

    if suspect.positive?
      puts "\nSuspect negatives — these are the renderer's first targets:"
      Posting.suspect_negatives.includes(:company).limit(10).each do |p|
        puts "  #{p.company.name} — #{p.role_title}"
      end
    end
  end
end
