namespace :analytics do
  desc "How the search is going, as on the Analytics page: the pipeline, the watch and the agents. Read-only. " \
       "[SECTION=pipeline|watch|agents] [SINCE=2026-10-01]"
  task report: :environment do
    sections = ENV["SECTION"].presence ? [ ENV["SECTION"] ] : Analytics::Text::SECTIONS
    unknown = sections - Analytics::Text::SECTIONS
    abort "SECTION is one of: #{Analytics::Text::SECTIONS.join(', ')}." if unknown.any?

    since = Date.iso8601(ENV["SINCE"]) if ENV["SINCE"].present?
    puts Analytics::Text.report(sections, since: since)
  rescue Date::Error
    abort "SINCE is a day as YYYY-MM-DD, not #{ENV['SINCE'].inspect}."
  end
end
