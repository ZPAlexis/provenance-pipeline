namespace :profile do
  desc "Your own links (4d), and what each read found: its pages, or why not. READ=1 reads them now, free (never the AI), " \
       "as the Profile page's \"Read them again\" does. They are edited on the Profile page."
  task links: :environment do
    links = SearchProfile.current&.profile_links.to_a
    abort "No link is saved: add your website or GitHub on the Profile page." if links.empty?

    if ENV["READ"] == "1"
      read = ProfileLinks.read!(links)
      puts "Read: #{read.summary}.", ""
      links = read.links
    end
    links.each do |link|
      puts "#{link.label} (#{link.url}): #{link.read_at ? "#{ProfileLinks.state(link)}, read #{link.read_at.to_date}" : 'not read yet'}"
      link.pages.each { |page| puts "  - #{page.title.presence || page.url} (#{page.words} words)" }
    end
  end
end
