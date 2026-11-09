module Verifier
  # Companies the operator's own Claude client proposes, as they may fit the operator (4b): each added as
  # "suggested", with why in `proposal`, and watched only once the operator, or the client on their word, tracks it.
  # Written as the client (agent:assistant), under a credential holding companies:suggest: a new company with its
  # name, domain and why, never a careers page; a proposal already on record has its why refreshed. A company tracked
  # or archived is refused, saying which: archiving a proposal declines it, so it is never proposed again.
  #
  # What a proposal's board lists is the app's own read, made here first and free (the worker runs with no API key,
  # through the board's own API), never the client's word. Why it may fit is the operator's business: its audit events
  # hold it by a hash alone.
  module Proposals
    ACTOR = "agent:assistant".freeze
    MAX = 10
    SOURCES = {
      "job_board_search" => "a job-board search", "lookalike" => "a lookalike of a company named", "news" => "the news",
      "list" => "a list", "linkedin" => "something pasted from LinkedIn", "other" => "another source"
    }.freeze

    # One company as the client gives it: its name and own domain, a link where its roles are listed (a known board's,
    # for the free read), why it may fit, where it was found (a SOURCES key, with the query or company it went by, and
    # its links: kept, never read).
    Candidate = Data.define(:name, :domain, :link, :why, :source, :query, :links) do
      def initialize(name:, why:, source:, domain: nil, link: nil, query: nil, links: [])
        super(name: name.to_s.squish, domain: domain.to_s.strip.presence, link: link.to_s.strip.presence,
              why: why.to_s.strip, source: source.to_s.strip, query: query.to_s.squish.presence,
              links: Array(links).map { |each| each.to_s.strip }.compact_blank.uniq)
      end
    end
    # What became of one: "created", "refreshed" (a proposal already, its why brought up to date), or "refused", with
    # why in a sentence.
    Outcome = Data.define(:candidate, :company, :status, :note)
    # What checking one found (4b step 4, check_company), recording nothing: the company on record it already is (nil
    # when none), what its board listed when read now (`seen`, as a proposal keeps it) and the roles there that fit the
    # profile, or why it couldn't be checked (`refusal`).
    Checked = Data.define(:candidate, :company, :seen, :fitting, :refusal)

    module_function

    # Saves each candidate, as the client, under its credential; each stands alone, so one refused leaves the rest. The
    # boards named are read first, free, before anything is written.
    def propose!(candidates, reported_model: nil, profile: SearchProfile.current, finder: nil, weigher: nil)
      raise ArgumentError, "at most #{MAX} companies a call" if candidates.size > MAX

      Authority.require_agent!(ACTOR)
      # Only the boards of those that will be saved are read: one refused on what it says, or on record and tracked or
      # archived, would wait a read for nothing.
      seen = seen(candidates.select { |candidate| proposable?(candidate) }, profile: profile, finder: finder, weigher: weigher)
      candidates.map { |candidate| one!(candidate, seen[candidate], reported_model) }
    end

    def proposable?(candidate)
      found = on_record!(candidate, domain!(candidate))
      found.nil? || found.suggested?
    rescue ArgumentError
      false
    end

    # Whether each candidate is on record, and in which state, and what its board lists now, read free; recording
    # nothing. A company on record and tracked or archived isn't read: it is never proposed. Asked of the operator's own
    # client before it proposes, so it proposes none on record and knows what each board holds.
    def check(candidates, profile: SearchProfile.current, finder: nil, weigher: nil)
      raise ArgumentError, "at most #{MAX} companies a call" if candidates.size > MAX

      looked = candidates.map do |candidate|
        [ candidate, on_record!(candidate, own_domain!(candidate)), nil ]
      rescue ArgumentError => e
        [ candidate, nil, e.message ]
      end
      unread = looked.filter_map { |candidate, company, refusal| candidate if refusal.nil? && (company.nil? || company.suggested?) }
      boards = read(unread, profile: profile, finder: finder, weigher: weigher)
      looked.map do |candidate, company, refusal|
        seen, fitting = boards[candidate]
        Checked.new(candidate: candidate, company: company, seen: seen, fitting: fitting || [], refusal: refusal)
      end
    end

    # Whose board it is, as the app's own read found it.
    OWNERS = { "confirmed" => "the board names the company", "unconfirmed" => "nothing ties the board to the company yet",
               "another company's" => "the board is another company's" }.freeze

    # What a board listed when read (a proposal's `seen`), in a sentence: its roles, how many fit the profile's titles,
    # and whose it is; or that none was read, and why. For the client and the commands.
    def seen_said(seen)
      return "no known board among its links: none read" if seen.blank?
      return "nothing read#{": #{seen['why'].to_s.delete_suffix('.')}" if seen['why']}" unless seen["board"]

      fitting = ", #{seen['fitting']} #{seen['fitting'] == 1 ? 'fits' : 'fit'} the profile's titles" if seen["fitting"]
      owner = OWNERS[seen["owner"]]
      "#{seen['board']}: #{seen['roles'].to_i} #{seen['roles'].to_i == 1 ? 'role' : 'roles'}#{fitting}#{"; #{owner}" if owner}" \
        "#{", read #{seen['read_at'].to_s[0, 10]}" if seen['read_at']}"
    end

    # The known board among a proposal's links, as its board's own page: the only link the app reads for it.
    def board_url(links)
      links.compact.each do |text|
        url = Capture.web(text)
        board = Capture.board(url) or next
        return Resolution.board_url(*board)
      rescue ArgumentError
        next
      end
      nil
    end

    # What each candidate's board lists, read now through its API (free, recording nothing), and how many of its
    # roles hold one of the profile's titles under the suggester's rules: { candidate => seen }. A candidate with no
    # known board among its links has none.
    def seen(candidates, profile:, finder: nil, weigher: nil)
      read(candidates, profile: profile, finder: finder, weigher: weigher).transform_values(&:first)
    end

    # The boards read, and the roles on each that fit the profile: { candidate => [seen, fitting roles] }, the roles as
    # the suggester weighs them (each with its listing).
    def read(candidates, profile:, finder: nil, weigher: nil)
      targets = candidates.each_with_index.filter_map do |candidate, index|
        url = board_url([ candidate.link, *candidate.links ]) or next
        { id: "c#{index}", label: candidate.name, domain: candidate.domain, name: candidate.name, url: url }
      end
      return {} if targets.empty?

      finder ||= Worker.new(run_dir: Worker.dir_for("own_board"), free: true)
      results = finder.run(targets, command: "own_board").results.index_by { |result| result["target_id"] }
      fitting = fitting(results, profile, weigher)
      candidates.each_with_index.to_h do |candidate, index|
        result = results["c#{index}"]
        roles = fitting["c#{index}"]
        [ candidate, ([ said(result, roles&.size), roles || [] ] if result) ]
      end.compact
    end

    def fitting(results, profile, weigher)
      return {} unless profile

      targets = results.filter_map do |id, result|
        check = Array(result["checks"]).first
        next unless check && check["outcome"] == "ok"

        { id: id, label: id, listings: check["listings"], profile: profile.to_worker, postings: [] }
      end
      return {} if targets.empty?

      weigher ||= Worker.new(run_dir: Worker.dir_for("suggest"), free: true)
      weigher.run(targets, command: "suggest").results.to_h do |result|
        [ result["target_id"], Array(result["roles"]).select { |role| role["suggested"] } ]
      end
    end

    def said(result, fitting)
      check = Array(result["checks"]).first
      unless check && check["outcome"] == "ok"
        return { "read" => "nothing read", "why" => result["evidence"] || result["reason"] || check&.dig("reason") }.compact
      end

      owner = case result["outcome"]
      when "resolved" then "confirmed"
      when "candidate" then "unconfirmed"
      else "another company's" if check["reason"] == "board_of_another_company"
      end
      { "board" => check["url"], "roles" => check["listing_count"], "fitting" => fitting, "owner" => owner,
        "read_at" => check["checked_at"] }.compact
    end

    def one!(candidate, seen, reported_model)
      domain = domain!(candidate)
      found = on_record!(candidate, domain)
      raise ArgumentError, refusal(found) if found && !found.suggested?

      company = found || Company.new(name: candidate.name, domain: domain, tracking: "suggested")
      company.proposal = { "why" => candidate.why, "source" => candidate.source, "query" => candidate.query,
                           "link" => candidate.link, "links" => candidate.links, "seen" => seen,
                           "written_by" => ACTOR, "reported_model" => reported_model.to_s.strip.presence }.compact
      ApplicationRecord.transaction do
        company.save!
        AuditEvent.record_write!(company, actor: ACTOR, digest: %w[proposal.why],
                                          reasoning: "#{found ? 'Proposal refreshed' : 'Proposed'} by the operator's own Claude client, " \
                                                     "found by #{SOURCES.fetch(candidate.source)}. Why it may fit is kept on the company alone.")
      end
      Outcome.new(candidate: candidate, company: company, status: found ? "refreshed" : "created",
                  note: "#{company.name} #{found ? 'was proposed already: its why is brought up to date' : 'proposed'}.")
    rescue ArgumentError, ActiveRecord::RecordInvalid => e
      Outcome.new(candidate: candidate, company: nil, status: "refused", note: "#{candidate.name.presence || 'A company'}: #{e.message}")
    end

    # The company's own domain, as Add by URL keeps it (careers.acme.com is acme.com), after what the candidate must say.
    def domain!(candidate)
      raise ArgumentError, "give the company's name" if candidate.name.blank?
      raise ArgumentError, "say why it may fit" if candidate.why.blank?
      raise ArgumentError, "say where it was found: one of #{SOURCES.keys.join(', ')}" unless SOURCES.key?(candidate.source)

      own_domain!(candidate)
    end

    def own_domain!(candidate)
      raise ArgumentError, "give the company's name" if candidate.name.blank?
      raise ArgumentError, "give the company's own domain (acme.com)" if candidate.domain.blank?

      Capture.parse(candidate.link) if candidate.link # a job board's link is refused here, as on the pages
      Capture.parse(candidate.domain).domain or
        raise ArgumentError, "#{candidate.domain} is a careers site's address, not the company's own domain"
    end

    # On record as Add by URL finds a company: by its domain, the board or careers page of its link, then its name.
    def on_record(candidate, domain)
      [ domain, candidate.link ].compact.each do |text|
        link = Capture.parse(text)
        found = Capture.owner(link)
        found ||= Company.find_by(careers_page_url: link.page) || Company.find_by(resolution_candidate_url: link.page) if link.page
        return found if found
      end
      Company.where("lower(name) = ?", candidate.name.downcase).first
    end

    # On record as Add by URL finds it; but a link that is another company's on record (its board or careers page, under
    # another domain and another name) is refused rather than taken for it: a proposal of one company is never written
    # onto another's.
    def on_record!(candidate, domain)
      found = on_record(candidate, domain) or return
      return found if found.domain.blank? || found.domain == domain || found.name.casecmp?(candidate.name)

      raise ArgumentError, "its link is #{found.name}'s, on record (#{found.domain}), not #{domain}'s: give the link to its own roles, or none"
    end

    def refusal(company)
      if company.dismissed?
        "#{company.name} is on record, archived (a proposal declined is never proposed again)"
      else
        "#{company.name} is on record, tracked already"
      end
    end

    private_class_method :proposable?, :read, :fitting, :said, :one!, :domain!, :own_domain!, :on_record, :on_record!, :refusal
  end
end
