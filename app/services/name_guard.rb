# The target list is private (review pass R10 and R11): no company on the record may be named in the public repo,
# by name or by domain. Checks the repo's files (tracked, and new ones not ignored) and the messages of commits not
# yet pushed, against the record; locally only, since only this machine holds the record.
#
# A name the repo may carry anyway (a tool the project uses that is also a company on the record) is allowed where it
# may appear; a name that is also a word ("range") is checked only as written, so the word passes and the company
# doesn't. Both are kept in a file beside the API key, outside the repo: they name companies on the record too, so
# they are as private as it is.
class NameGuard
  ALLOWED_FILE = Pathname.new(Dir.home).join(".config/provenance-pipeline/names_allowed.yml")
  # Generated or binary: nothing a person wrote.
  SKIPPED = /\.(lock|png|ico|jpe?g|gif|pdf|dump|bundle)\z/

  # A line naming a company on the record: where, which line, and what it names (a name and its domain, say).
  Finding = Data.define(:where, :line, :names)

  # The record's names and domains, and the allowances kept beside it: `words`, the names checked only as written,
  # and `allowed`, each name or domain with where it may appear.
  def self.from_record(allowed_file: ALLOWED_FILE)
    kept = allowed_file.exist? ? YAML.safe_load(allowed_file.read).to_h : {}
    new(names: Company.distinct.pluck(:name), domains: Company.distinct.pluck(:domain),
        words: Array(kept["words"]), allowed: kept["allowed"].to_h)
  end

  # The repo's files, tracked and new (each by its path), and its commits on no remote yet (each as "commit <id>").
  def self.repo_texts(root = Rails.root)
    git = ->(*args) { IO.popen([ "git", "-C", root.to_s, *args ], &:read).force_encoding("UTF-8").scrub("") }
    files = git.("ls-files", "--cached", "--others", "--exclude-standard", "-z").split("\0")
                .reject { |path| path.match?(SKIPPED) || !root.join(path).file? }
                .to_h { |path| [ path, root.join(path).read(encoding: "UTF-8").scrub("") ] }
    messages = git.("log", "--branches", "--not", "--remotes", "--format=%h%x00%B%x01").split("\x01").map(&:strip)
                  .reject(&:empty?).to_h { |entry| id, body = entry.split("\x00", 2); [ "commit #{id}", body.to_s ] }
    files.merge(messages)
  end

  # `words`: names that are also words, checked only as written. `allowed`: each name or domain the repo may carry,
  # with where (path globs; "*" anywhere, commit messages too).
  def initialize(names:, domains:, words: [], allowed: {})
    @words = words.to_set
    @patterns = names.compact_blank.uniq.map { |name| [ name, name_pattern(name) ] } +
                domains.compact_blank.uniq.reject { |domain| domain.end_with?(".example") }
                       .map { |domain| [ domain, /(?<![\w-])#{Regexp.escape(domain)}(?![\w-])/i ] }
    @allowed = allowed.transform_values { |globs| Array(globs) }
  end

  # Each line in `texts` ({ where => text }) naming a company on the record, where it isn't allowed.
  def findings(texts)
    texts.flat_map do |where, text|
      named = @patterns.select { |name, pattern| text.match?(pattern) && !allowed?(name, where) }
      next [] if named.empty?

      text.each_line.with_index(1).filter_map do |line, number|
        names = named.filter_map { |name, pattern| name if line.match?(pattern) }
        Finding.new(where:, line: number, names:) if names.any?
      end
    end.sort_by { |finding| [ finding.where, finding.line ] }
  end

  private

  # A name of four letters or more, in any case, as a whole word (as written, when it is also a word); a shorter one
  # only as written, and not inside a path or a word, where it is far more often something else.
  def name_pattern(name)
    escaped = Regexp.escape(name)
    return /(?<![\w.\/-])#{escaped}(?![\w\/-])/ if name.length < 4
    return /(?<![[:alnum:]])#{escaped}(?![[:alnum:]])/ if @words.include?(name)

    /(?<![[:alnum:]])#{escaped}(?![[:alnum:]])/i
  end

  def allowed?(name, where)
    @allowed.fetch(name, []).any? { |glob| File.fnmatch?(glob, where, File::FNM_EXTGLOB | File::FNM_DOTMATCH) }
  end
end
