namespace :clay do
  desc "Import Clay CSV exports. Usage: [VERIFIED_AT=YYYY-MM-DD] [SLICE=name] rails clay:import[path/to/dir_or_file] " \
       "(VERIFIED_AT is required when an export carries verdicts; SLICE names a single file's slice outright)"
  task :import, [ :path ] => :environment do |_t, args|
    path = args[:path] or abort "Usage: [VERIFIED_AT=YYYY-MM-DD] [SLICE=name] rails clay:import[path/to/dir_or_file]"
    pathname = Pathname.new(path)
    abort "Not found: #{path}" unless pathname.exist?

    # When the export's verdicts were reached. Clay carries no per-row date, so
    # it is required whenever an export has verdicts; the import refuses to
    # write anything without it.
    verified_at = ENV["VERIFIED_AT"].presence

    # For a table whose filename does not end in its slice. One file at a time,
    # so a directory's files are never all tagged with one slice by mistake.
    slice = ENV["SLICE"].presence&.downcase
    abort "SLICE names one file's slice; import that file on its own." if slice && pathname.directory?

    results =
      begin
        if pathname.directory?
          ClayImporter.import_dir(pathname, verified_at: verified_at)
        else
          [ [ pathname.basename.to_s, ClayImporter.call(pathname, slice: slice, verified_at: verified_at) ] ]
        end
      rescue ClayImporter::MissingVerifiedAt => e
        abort e.message
      rescue ArgumentError => e
        abort "VERIFIED_AT must be ISO 8601 (e.g. 2026-09-22 or 2026-09-22T15:30:00Z): #{e.message}"
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
