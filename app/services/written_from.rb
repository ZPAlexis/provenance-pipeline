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

  # The background version the client read (4c), by the short version it was given, as the resume's is found.
  def background!(background_version, reread:)
    backgrounds = SearchProfile.current&.backgrounds&.newest_first.to_a
    raise ArgumentError, "no background is saved: it is pasted on the Profile page" if backgrounds.empty?

    backgrounds.find { |version| version.version == background_version.to_s.strip.downcase } or
      raise ArgumentError, "background version #{background_version.inspect} isn't on record: read #{reread} again, and cite its lines as they are now"
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

  # Points that each name lines: [{ key, "lines" => [{ "line", "text" }] }], a point with nothing said left out. Since 4c a
  # point may also name background lines (`background_lines`: B4, or 4), resolved only within `part` of the background
  # version read: a point that names them is drawn from the background, to be confirmed by the operator.
  def with_lines(resume, items, key, background: nil, part: nil)
    dropped = 0
    cited = Array(items).filter_map do |item|
      item = plain(item)
      said = item[key].to_s.strip
      next if said.empty?

      lines, missing = resume.cite(item["lines"])
      dropped += missing
      from = Array(item["background_lines"])
      next { key => said, "lines" => lines } if from.empty?
      raise ArgumentError, "give the background version you read: its lines are cited against it" unless background && part

      found, gone = background.cite(from, parts: [ part ])
      dropped += gone
      { key => said, "lines" => lines, "background_lines" => found }.reject { |name, value| name == "background_lines" && value.empty? }
    end
    [ cited, dropped ]
  end

  # Whether any of the items given cites a background line (4c): a line drawn on named "B3", or `background_lines`.
  def cites_background?(*lists)
    lists.flatten.any? { |item| (item = plain(item)) && (item["line"].to_s.strip.match?(/\AB\d/i) || Array(item["background_lines"]).any?) }
  end

  # The background version a piece of writing read (4c), when it says one, and the part its kind may use; nil when it
  # names none. A version given for a kind that reads no part of it is refused.
  def background_read!(background_version, part, reread:)
    return if background_version.to_s.strip.empty?
    raise ArgumentError, "this kind of writing reads no part of the background" unless part

    background!(background_version, reread: reread)
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
