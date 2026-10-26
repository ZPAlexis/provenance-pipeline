# What a piece of writing about an application was written from (Stage 2d), for what the operator's own Claude
# client saves through MCP: the resume version the client read (found by the short version the materials gave
# it, so the lines it cites are read against the lines it saw), the role's newest description, and the points
# it makes resolved to the resume's own lines. A number the resume doesn't have is dropped and counted.
module WrittenFrom
  module_function

  def sources!(application, resume_version)
    resume = resume!(resume_version, reread: "the application's materials")
    description = application.posting.role_descriptions.newest_first.first
    raise ArgumentError, "the role's description isn't read yet: it is read from the role's page in the app" unless description

    [ resume, description ]
  end

  # The resume version the client read, by the short version it was given; `reread` names where to read it again.
  def resume!(resume_version, reread:)
    resumes = SearchProfile.current&.resumes&.newest_first.to_a
    raise ArgumentError, "no resume is saved: it is pasted on the Profile page" if resumes.empty?

    resumes.find { |version| version.version == resume_version.to_s.strip.downcase } or
      raise ArgumentError, "resume version #{resume_version.inspect} isn't on record: read #{reread} again, and cite the lines as they are now"
  end

  # A letter's or a note's lines drawn on: [{ "line", "text", "used_for" }], as the in-app drafter keeps them.
  def drawn_on(resume, items)
    dropped = 0
    cited = Array(items).filter_map do |item|
      item = plain(item)
      found, missing = resume.cite([ item["line"] ])
      dropped += missing
      found.first&.merge("used_for" => item["answers"].to_s.strip)
    end
    [ cited.uniq { |point| point["line"] }, dropped ]
  end

  # Points that each name lines: [{ key, "lines" => [{ "line", "text" }] }], a point with nothing said left out.
  def with_lines(resume, items, key)
    dropped = 0
    cited = Array(items).filter_map do |item|
      item = plain(item)
      said = item[key].to_s.strip
      next if said.empty?

      lines, missing = resume.cite(item["lines"])
      dropped += missing
      { key => said, "lines" => lines }
    end
    [ cited, dropped ]
  end

  def gaps(items)
    Array(items).filter_map do |item|
      item = plain(item)
      { "asks" => item["asks"].to_s.strip, "note" => item["note"].to_s.strip } if item["asks"].to_s.strip.present?
    end
  end

  # The model a client says it is: recorded as reported, never checked.
  def reported(model) = model.to_s.strip.presence&.truncate(80)

  # An item as a client sends it, keys as strings (they arrive as symbols).
  def plain(item) = item.respond_to?(:to_h) ? item.to_h.transform_keys(&:to_s) : {}

  def counted(count, what) = "#{count} #{what.pluralize(count)}"

  # What a summary says of the lines a writer named that the resume doesn't have; nothing when there are none.
  def dropped(count)
    "; #{counted(count, 'line')} it named #{count == 1 ? "isn't" : "aren't"} in the resume, left out" if count.positive?
  end
end
