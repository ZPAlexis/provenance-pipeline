# The operator's background beyond the resume (4c), pasted on the Profile page in three parts, each read only by what
# may use it. Kept version by version, as the resume is, through Backgrounds, which audits each part by its size and
# hash, never its text. Personal data, held in this database only; the operator writes in it only what is safe to
# quote, since their own AI assistant may hold all of it in one conversation.
class Background < ApplicationRecord
  # Each part, as the Profile page names it, and what reads it.
  PARTS = {
    "looking_for" => {
      label: "What I'm looking for",
      use: "Motivation only. Read by role fit, and by cover letters and outreach notes, never as a claim of experience: " \
           "every claim in a draft still traces to a line of your resume.",
      placeholder: "A long-term role building the systems a revenue team runs on…", rows: 3
    },
    "role_preferences" => {
      label: "Role preferences",
      use: "Read only by role fit, never by a draft: the titles you want, the seniority, the work you want it to be, " \
           "signals to look for in a posting, weaker fits, how and where you work.",
      placeholder: "Titles: …\nSeniority: …\nWhat I want the work to be: …", rows: 8
    },
    "not_on_resume" => {
      label: "Background not on the resume",
      use: "Read by role fit, and by resume reviews and tailored resumes, which flag anything drawn from it as \"from your " \
           "background, not on the resume\" for you to confirm. Cover letters and outreach notes never claim it.",
      placeholder: "Languages and work authorization: …\nWhat the resume compresses: …\nSkill scope: …", rows: 10
    }
  }.freeze
  # A part's most: the fit scorer weighs everything it is given, so a long background crowds out the resume.
  MAX_CHARS = 10_000

  belongs_to :search_profile

  validates :content_hash, presence: true
  validate :said_something

  scope :newest_first, -> { order(created_at: :desc) }

  # A version's parts, as given: each trimmed, a blank one nil.
  def self.parts(given)
    given = given.to_h.transform_keys(&:to_s)
    PARTS.keys.to_h { |part| [ part, given[part].to_s.gsub("\r\n", "\n").strip.presence ] }
  end

  # A version built from its parts, with each part's hash and the whole's.
  def self.of(profile, given)
    parts = parts(given)
    hashes = parts.to_h { |part, text| [ "#{part}_hash", (Resume.digest(text) if text) ] }
    whole = Resume.digest(PARTS.keys.map { |part| "#{part}=#{hashes["#{part}_hash"]}" }.join("\n"))
    profile.backgrounds.new(parts.merge(hashes).merge("content_hash" => whole))
  end

  def text_of(part) = public_send(PARTS.key?(part.to_s) ? part : raise(ArgumentError, "no part #{part.inspect}")).to_s

  # A part's hash, as the readers of that part record it; nil while it is blank.
  def hash_of(part) = public_send("#{part}_hash")

  # Its words, or a part's, counted line by line as its lines are numbered.
  def words(part = nil) = part ? Resume.lines_of(text_of(part)).sum { |line| line.split.size } : PARTS.keys.sum { |each| words(each) }

  # A short name for this version, from its hash: what a client that read it gives back when it saves what it read.
  def version = content_hash.delete_prefix("sha256:")[0, 12]

  # Every part's non-blank lines, numbered from 1 across the parts in order, each with its part: [[number, line, part]].
  # A number names the same line for every reader, whichever parts it is given. Since 4d, a reading for one role may
  # carry the lines of the operator's links that apply to it (with_links): numbered on after the parts, as part LINKS,
  # each with the page it is from: [number, line, LINKS, source].
  def numbered_lines
    number = 0
    parts = PARTS.keys.flat_map { |part| Resume.lines_of(text_of(part)).map { |line| [ number += 1, line, part ] } }
    parts + link_excerpts.flat_map { |page| page["lines"].map { |line| [ number += 1, line, LINKS, page["title"].presence || page["url"] ] } }
  end

  # The numbered lines of the parts given.
  def lines_of(*parts) = numbered_lines.select { |_, _, part| parts.map(&:to_s).include?(part) }

  # The lines `numbers` name among `parts`, with their text and part (and, for a line of the links, the page it is
  # from), in the order given and once each; and how many name no line there.
  def cite(numbers, parts: PARTS.keys)
    lines = lines_of(*parts).to_h { |number, line, part, source| [ number, { "text" => line, "part" => part, "source" => source }.compact ] }
    named = Array(numbers).map { |number| Integer(number.to_s.delete_prefix("B"), exception: false) }
    cited = named.uniq.filter_map { |number| { "line" => number, **lines[number] } if lines.key?(number) }
    [ cited, named.count { |number| !lines.key?(number) } ]
  end

  # What the operator's links show that applies to one role (4d), as a part a reading may cite after its own.
  LINKS = "links".freeze

  # The pages and lines of the links read with this version for one role ([{ "url", "title", "lines" }]): set for one
  # reading by with_links, never kept.
  attr_writer :link_excerpts

  def link_excerpts = @link_excerpts || []

  # This version, read for one role with the lines of the operator's links that apply to it: a separate instance, so
  # each role's reading numbers its own.
  def with_links(excerpts)
    return self if excerpts.blank?

    self.class.find(id).tap { |reading| reading.link_excerpts = excerpts }
  end

  # The parts a reader of `part` may cite: since 4d with the links' lines too, when read with them (never for what the
  # operator is looking for, which is cited by no reader).
  def citable(*parts)
    parts = PARTS.keys if parts.empty?
    link_excerpts.any? && parts.map(&:to_s) != [ "looking_for" ] ? [ *parts, LINKS ] : parts
  end

  # A short name for the links' lines read with this version (4d), what a client gives back with what it cites from
  # them; nil when there are none.
  def links_version = (Resume.digest(link_excerpts.to_json).delete_prefix("sha256:")[0, 12] if link_excerpts.any?)

  private

  def said_something
    errors.add(:base, "write at least one part first") if PARTS.keys.all? { |part| public_send(part).blank? }
  end
end
