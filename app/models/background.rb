# The operator's background beyond the resume (4c), pasted on the Profile page in three parts, each read only by what
# may use it. Kept version by version, as the resume is, through Backgrounds, which audits each part by its size and
# hash, never its text. Personal data, held in this database only; the operator writes in it only what is safe to
# quote, since their own Claude client may hold all of it in one conversation.
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
  # A number names the same line for every reader, whichever parts it is given.
  def numbered_lines
    number = 0
    PARTS.keys.flat_map { |part| Resume.lines_of(text_of(part)).map { |line| [ number += 1, line, part ] } }
  end

  # The numbered lines of the parts given.
  def lines_of(*parts) = numbered_lines.select { |_, _, part| parts.map(&:to_s).include?(part) }

  # The lines `numbers` name among `parts`, with their text and part, in the order given and once each; and how many
  # name no line there.
  def cite(numbers, parts: PARTS.keys)
    lines = lines_of(*parts).to_h { |number, line, part| [ number, [ line, part ] ] }
    named = Array(numbers).map { |number| Integer(number.to_s.delete_prefix("B"), exception: false) }
    cited = named.uniq.filter_map { |number| { "line" => number, "text" => lines[number][0], "part" => lines[number][1] } if lines.key?(number) }
    [ cited, named.count { |number| !lines.key?(number) } ]
  end

  private

  def said_something
    errors.add(:base, "write at least one part first") if PARTS.keys.all? { |part| public_send(part).blank? }
  end
end
