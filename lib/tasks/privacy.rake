namespace :privacy do
  desc "Check that no company on the record is named in the repo: its files (tracked, and new ones not ignored) and " \
       "the messages of commits not yet pushed, by name or domain. The target list is private. Read-only; local " \
       "CI runs it. Allowances, private too, in ~/.config/provenance-pipeline/names_allowed.yml."
  task names: :environment do
    next puts("No company on record: nothing to check the repo against.") if Company.none?

    texts = NameGuard.repo_texts
    found = NameGuard.from_record.findings(texts)
    commits = texts.count { |where, _| where.start_with?("commit ") }
    if found.empty?
      puts "No company on the record is named in the repo: #{texts.size - commits} files and " \
           "#{commits} unpushed #{commits == 1 ? 'commit' : 'commits'} checked."
      next
    end

    found.each { |finding| puts "#{finding.where}:#{finding.line}: #{finding.names.join(', ')}" }
    abort "\n#{found.size} #{found.one? ? 'place names' : 'places name'} a company on the record: the target list is " \
          "private. Name a made-up company instead (Acme, Contoso), or, for a tool or word the repo may carry, allow " \
          "it where it may appear in #{NameGuard::ALLOWED_FILE}."
  end
end
