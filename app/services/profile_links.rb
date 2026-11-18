# The operator's own links (4d): their website, their GitHub, or another portfolio, at most ProfileLink::MAX, kept with
# the search profile, never LinkedIn. Saved by the operator alone, audited by each link's label and address as hashes
# (they name the operator). Read by the app, free and never by the LLM (the worker's `portfolio`, started with no API
# key), as the verifier, under a credential holding evidence:write alone: each page kept as a version, as a role's
# description is. A run's files hold the pages' text, so they are removed when the run ends.
module ProfileLinks
  SCOPES = %w[evidence:write].freeze

  # What a read found, answering a check run as a check's outcome does (CheckNowJob): free.
  Read = Data.define(:links, :summary, :run_id) do
    def finished? = links.any? { |link| link.read_outcome == "ok" }

    def answer = finished? ? "read" : "not read"

    def tally = links.map(&:read_outcome).compact.tally

    def cost_usd = 0.0
  end

  # What applies to one role, at most (4d step 4): every page's lines together, a page's, and a line's.
  BUDGET = 6_000
  PAGE_BUDGET = 2_000
  LINE_CHARS = 400
  # The role's words a line shares, at least, to apply to it: a description has hundreds, so one alone is chance.
  MIN_SHARED = 2
  # Words too common to say a page and a role are about the same thing.
  COMMON = %w[about also and been being both from have here into just like make many more most much must only other our
              over some such than that their them then there these they this those very what when where which while will
              with work would year your role team experience].to_set.freeze

  module_function

  # What the operator's links show that applies to the role `description` describes: of every line of the links'
  # newest reads, those sharing the most of the description's words (MIN_SHARED at least), within BUDGET characters
  # (PAGE_BUDGET a page, LINE_CHARS a line); the page with the best line first, each page's lines in its own order.
  # [{ "url", "title", "lines" }], none when nothing applies. The same pages and description always give the same
  # lines, so what a client cites can be read back. (A rehearsal on the operator's own links, 2026-11-18: lines picked
  # by the page in page order gave five roles the same three pages; ranked by line, each role its own.)
  def applicable(profile, description)
    terms = words(description)
    return [] if terms.empty? || profile.nil?

    ranked = profile.profile_links.to_a.flat_map(&:pages).flat_map do |page|
      Resume.lines_of(page.text).each_with_index.filter_map do |line, index|
        shared = words(line).intersection(terms).size
        [ -shared, page.url, index, page, line.truncate(LINE_CHARS) ] if shared >= MIN_SHARED
      end
    end
    left, used = BUDGET, Hash.new(0)
    kept = ranked.sort_by { |rank| rank.first(3) }.select do |_, url, _, _, line|
      next false if line.size > left || used[url] + line.size > PAGE_BUDGET

      used[url] += line.size
      left -= line.size
    end
    kept.group_by { |rank| rank[3] }.map do |page, lines|
      { "url" => page.url, "title" => page.title, "lines" => lines.sort_by { |rank| rank[2] }.map(&:last) }
    end
  end

  # The background as one role is read with it (4d): with the lines of the operator's links that apply to the role
  # described, when they have links; the background as it is otherwise (or nil, with none saved).
  def reading(background, profile, description)
    return background unless background && description && profile&.profile_links&.any?

    background.with_links(applicable(profile, description.text))
  end

  # A text's words that can say what it is about: four letters or more, a plural read as its singular ("agents" as
  # "agent"), the common ones left out.
  def words(text)
    text.to_s.downcase.scan(/[[:alnum:]][[:alnum:]+#]*/).filter_map do |word|
      next if word.size < 4

      word.size > 4 && word.end_with?("s") && !word.end_with?("ss") ? word.chop : word
    end.to_set - COMMON
  end

  # Keeps `given` ([{ label:, url: }], in order; an empty row is left out) as the profile's links: a new address added,
  # one gone removed (its pages with it), a label or order changed kept; each audited as the operator's. An address with
  # no scheme is taken as https. Returns the links now.
  def keep!(profile, given, actor: AuditEvent::OPERATOR)
    raise ArgumentError, "save the profile first: the links are kept with it" unless profile&.persisted?

    rows = rows(given)
    raise ArgumentError, "keep at most #{ProfileLink::MAX} links" if rows.size > ProfileLink::MAX

    current = profile.profile_links.reload.to_a
    ApplicationRecord.transaction do
      kept = rows.each_with_index.map do |(label, url), position|
        # Built apart from the profile's links, so one refused leaves nothing behind on it.
        link = current.find { |existing| existing.url == url } || ProfileLink.new(search_profile: profile, url: url)
        before = facts(link) if link.persisted?
        link.assign_attributes(label: label, position: position)
        raise ArgumentError, "#{url}: #{refusal(link)}" unless link.valid?
        next link unless link.new_record? || link.changed?

        link.save!
        AuditEvent.record!(actor: actor, action: before ? "update" : "create", target: link, changes_made: changes(before, facts(link)),
                           reasoning: "Link #{before ? 'changed' : 'added'} on the Profile page (#{link.host}).")
        link
      end
      (current - kept).each do |link|
        AuditEvent.record!(actor: actor, action: "destroy", target: link, changes_made: changes(facts(link), nil),
                           reasoning: "Link removed on the Profile page, with the #{link.link_pages.count} page versions read from it.")
        link.destroy!
      end
      kept
    end.tap { profile.profile_links.reset }
  end

  # Reads `links` in one run, free: each one's pages kept as versions, and what came of it on the link. Returns a Read.
  def read!(links, worker: Verifier::Worker.new(run_dir: Verifier::Worker.dir_for("portfolio"), free: true),
            issued_by: AuditEvent::OPERATOR)
    links = Array(links)
    raise ArgumentError, "there is no link to read: add one on the Profile page" if links.empty?

    Authority.run(Verifier::Ingest::ACTOR, scopes: SCOPES, purpose: "portfolio: #{WrittenFrom.counted(links.size, 'link')}",
                                           ttl: Authority::ONE, issued_by: issued_by) do
      run = begin
        worker.run(links.map { |link| { id: link.id, url: link.url, label: link.label } }, command: "portfolio")
      ensure
        Verifier::Worker.forget!(worker.run_dir) # its results hold the pages' text; the record keeps it
      end
      by_id = links.index_by(&:id)
      run.results.each { |result| record(result, by_id, run.id) }
      by_id.each_value do |link|
        link.update!(read_at: Time.current, read_outcome: "error", read_reason: run.stopped || "no result written", read_skipped: 0)
      end
      links.each(&:reload)
      Read.new(links: links, summary: said(links), run_id: run.id)
    end
  end

  # One result through the contract, then kept on its link (removed from `by_id`): a page with the same text as before
  # only says when it was seen; a changed or new one is a new version.
  def record(result, by_id, run_id)
    link = by_id.delete(result.try(:[], "target_id")) or return
    errors = Verifier::ResultContract.portfolio_errors(result)
    at = errors.empty? && result["checked_at"] ? Time.iso8601(result["checked_at"]) : Time.current
    if errors.any? || result["outcome"] != "ok"
      reason = errors.any? ? "not recorded: #{errors.join('; ')}" : result["reason"]
      return link.update!(read_at: at, read_outcome: errors.any? ? "error" : result["outcome"], read_reason: reason, read_skipped: 0)
    end

    result["pages"].each do |page|
      seen = link.link_pages.where(url: page["url"]).order(last_read_at: :desc).first
      next seen.update!(last_read_at: at) if seen&.content_hash == page["content_hash"]

      link.link_pages.create!(url: page["url"], title: page["title"], text: page["text"], content_hash: page["content_hash"],
                              read_via: page["read_via"], run_id: run_id, first_read_at: at, last_read_at: at)
    end
    link.update!(read_at: at, read_outcome: "ok", read_reason: nil, read_skipped: result["skipped"].to_i)
  end

  # The rows given, as [label, url]: each address stripped (https when it names no scheme), a label from its host when
  # none is given.
  def rows(given)
    Array(given).filter_map do |row|
      row = WrittenFrom.plain(row)
      label, url = row["label"].to_s.strip, row["url"].to_s.strip
      next if url.empty?

      url = "https://#{url}" unless url.match?(%r{\A[a-z][a-z0-9+.-]*://}i)
      [ label.presence || URI.parse(url).host.to_s.delete_prefix("www.").presence || url, url ]
    rescue URI::InvalidURIError
      [ label.presence || url, url ]
    end
  end

  # What a read found, in a sentence, counts alone: "Website: 6 pages; GitHub: 9 pages; Blog: refused (robots.txt)".
  def said(links)
    links.map { |link| "#{link.label}: #{state(link)}" }.join("; ")
  end

  def state(link)
    case link.read_outcome
    when nil then "not read yet"
    when "ok" then "#{WrittenFrom.counted(link.pages.size, 'page')}#{", #{link.read_skipped} left unread" if link.read_skipped.positive?}"
    when "blocked" then "refused (robots.txt keeps us off it)"
    when "gone" then "not there (#{link.read_reason})"
    else "couldn't be read (#{link.read_reason})"
    end
  end

  # Why a link can't be kept, in words: "LinkedIn isn't read: …", "its address must be a web address (http or https)".
  def refusal(link)
    link.errors.map { |error| error.attribute == :base ? error.message : "its #{error.attribute == :url ? 'address' : error.attribute} #{error.message}" }
        .to_sentence
  end

  # What a link's audit events say of it: its label and address as hashes (they name the operator), and its place.
  def facts(link) = { "label_hash" => Resume.digest(link.label), "url_hash" => Resume.digest(link.url), "position" => link.position }

  def changes(before, after)
    (before || {}).keys.union((after || {}).keys).to_h { |key| [ key, [ before&.dig(key), after&.dig(key) ] ] }
                  .reject { |_, (was, now)| was == now }
  end

  private_class_method :record, :rows, :facts, :changes, :refusal
end
