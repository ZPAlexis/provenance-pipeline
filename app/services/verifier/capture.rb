module Verifier
  # Adding to the watch list by hand (1.5d): a company from its domain, its
  # careers page, or its ATS board; a role from its own page at the employer,
  # its title as the operator reads it, and where they found it. Only the
  # operator adds, and each addition is audited as theirs. Nothing is fetched
  # here: the first read is a check now, which finds the company's careers page
  # first when there is none, trying the page the link gave.
  module Capture
    ACTOR = AuditEvent::OPERATOR

    # Job boards list other companies' roles, and are never fetched: never a careers page,
    # nor a role's own page. A job board's link sits beside a role, as where it was found.
    JOB_BOARDS = /(?:\A|\.)(?:linkedin\.com|indeed\.com|glassdoor\.com|ziprecruiter\.com|wellfound\.com|angel\.co|
                  monster\.com|simplyhired\.com|jooble\.org|talent\.com|builtin\.com|remoteok\.com|
                  weworkremotely\.com|remotive\.com)\z/x

    # Mirrors workers/verifier/src/verifier/ats.py detect: a known ATS board in a link, whatever page of it.
    BOARDS = {
      "greenhouse" => %r{\Ahttps?://(?:boards|job-boards)(?:\.eu)?\.greenhouse\.io/(?!embed/)([\w-]+)},
      "lever" => %r{\Ahttps?://jobs(?:\.eu)?\.lever\.co/([\w.-]+)},
      "ashby" => %r{\Ahttps?://jobs\.ashbyhq\.com/([\w.%-]+)}
    }.freeze
    GREENHOUSE_EMBED = %r{\Ahttps?://(?:boards|job-boards)(?:\.eu)?\.greenhouse\.io/embed/job_board}
    WORKDAY = %r{\Ahttps?://([\w-]+)\.(wd\d+)\.myworkdayjobs\.com/(?:[a-z]{2}-[A-Z]{2}/)?(?!wday/)([\w-]+)}
    # An Oracle Cloud careers site, with the place its page is filtered to (?locationId=), as ats.py reads it.
    ORACLE = %r{\Ahttps?://([\w-]+)\.fa\.([\w-]+)\.oraclecloud\.com/hcmUI/CandidateExperience/[\w-]+/sites/([\w-]+)}

    # Careers sites hosted for many companies: the host names the vendor, never the company.
    HOSTED = /(?:\A|\.)(?:gupy\.io|recruitee\.com|teamtailor\.com|bamboohr\.com|breezy\.hr|workable\.com|
              smartrecruiters\.com|personio\.(?:de|com)|jobvite\.com|icims\.com|taleo\.net|successfactors\.(?:com|eu)|
              pinpointhq\.com|applytojob\.com|comeet\.com|freshteam\.com|zohorecruit\.com|rippling\.com|
              myworkdayjobs\.com|oraclecloud\.com|greenhouse\.io|lever\.co|ashbyhq\.com)\z/x
    # Leading labels that name a careers site, not the company: careers.acme.com is acme.com.
    SITE_LABELS = %w[www careers career jobs job work apply join talent boards job-boards].freeze

    # A LinkedIn job's id, in whatever link to it: /jobs/view/<slug>-<id>, /jobs/view/<id>, ?currentJobId=<id>.
    LINKEDIN_JOB = %r{(?:/jobs/view/(?:[^/?#]*-)?|[?&]currentJobId=)(\d{6,})}
    # Mirrors workers/verifier/src/verifier/links.py TRACKING: query parameters that track a visit, not a role.
    TRACKING = %w[utm_ gh_src trk].freeze
    SAME_HOSTS = { "boards.greenhouse.io" => "job-boards.greenhouse.io", "boards.eu.greenhouse.io" => "job-boards.eu.greenhouse.io" }.freeze

    # What a pasted link or domain says: where the company's roles may be listed, and who it is.
    Link = Data.define(:url, :page, :domain, :board, :name)
    # A company added or found, and whether finding it tracked it again (it was archived).
    Added = Data.define(:company, :created, :note, :tracked_again) do
      def initialize(company:, created:, note:, tracked_again: false) = super
    end
    Placed = Data.define(:posting, :created, :note)

    module_function

    # The company the operator pasted, found or added. A page given in the link (a careers page, an ATS board) is
    # kept as the one to try first while the company has no watched page. A careers page given apart (4a) is
    # watched as given, set by hand, so the company is watched with no read; one already watched is never changed
    # here. Nothing is written when anything is refused.
    def company!(input, name: nil, page: nil, actor: ACTOR)
      link = parse(input)
      given = careers_page(page) if page.to_s.strip.present? # refused, if it is, before anything is written
      ApplicationRecord.transaction do
        added = company_from(link, name, actor)
        given ? watched_at!(added, given, actor) : added
      end
    end

    # The role the operator pasted, tracked: pasting it is choosing it. Found on record by
    # where it was found (its LinkedIn job), its own link, or its title at the company when
    # that has no link yet; a suggested or dismissed role is tracked, its missing links filled in.
    # A new role needs its title, unless a check follows (`check:`), which reads one from its own page; till then it
    # waits, named "(title pending)". From a company's page (`company:`, 4a), the role is added there: refused at an
    # archived company, or for a link on another company's site or board on record. Nothing is written when
    # anything is refused.
    def role!(link:, title: nil, location: nil, source: nil, company_name: nil, company: nil, check: false, actor: ACTOR)
      title = title.to_s.squish
      own = parse(link, role: true)
      source = source_link(source)
      at_company!(company, own) if company
      ApplicationRecord.transaction do
        known = by_source(source)
        elsewhere!(known, company) if known && company
        added = company_from(own, company_name, actor) unless known || company
        company ||= known&.company || added.company
        again = chosen_again(company, own.url, actor) if known # a role found by where it was found, at an archived company
        known ||= by_link(company, own.url) || (by_title(company, title) if title.present?)
        placed = known ? choose!(known, own, source, actor) : create_role!(company, own, title.presence, location, source, check, actor)
        before = again || (added.note if added&.created || added&.tracked_again)
        before ? placed.with(note: "#{before} #{placed.note}") : placed
      end
    end

    # A role's own page at the employer, as the operator gives it (4a): the link each check tries first to find it.
    # An employer's page or its ATS posting, never a job board's, never on another company's site or board on
    # record, and never another role's there. Audited as theirs, with their note if they give one.
    def own_page!(posting, link, note: nil, actor: ACTOR)
      own = parse(link, role: true)
      at_company!(posting.company, own, archived: true)
      raise ArgumentError, "that is already its own page" if posting.job_url && link_key(posting.job_url) == link_key(own.url)
      if (other = by_link(posting.company, own.url))
        raise ArgumentError, "that link is #{other.role_title}'s own page, on record at #{posting.company.name}"
      end

      ApplicationRecord.transaction do
        posting.update!(job_url: own.url)
        AuditEvent.record_write!(posting, actor: actor, reasoning: [ "Its own page set by hand.", note.to_s.squish.presence ].compact.join(" "))
      end
      posting
    end

    def parse(input, role: false)
      text = input.to_s.strip
      raise ArgumentError, role ? "paste the link to the role's own page" : "paste a company's domain, careers page, or ATS board" if text.empty?

      url = web(text)
      if host(url).match?(JOB_BOARDS)
        instead = role ? "the role's own page at the employer, or on its ATS; the job board's link can go in where you found it" :
                         "the employer's domain or careers page"
        raise ArgumentError, "that link is on #{host(url).delete_prefix('www.')}, a job board: its links are never read. Paste #{instead} instead."
      end

      board = board(url)
      hosted = host(url).match?(HOSTED)
      domain = (company_domain(host(url)) unless hosted)
      Link.new(url: url, page: page(url, board, hosted, role), domain: domain, board: board, name: guessed_name(url, board, domain))
    end

    # Where the company's roles are listed, as the link shows it: its board's own page (whichever
    # page of the board was pasted), a hosted careers site, or the page itself. A bare domain names
    # none, nor does a role's page on the company's own site: its careers page is found from the domain.
    def page(url, board, hosted, role)
      return Resolution.board_url(*board) if board
      return hosted_site(url) if hosted && role
      return url if hosted

      url if !role && URI.parse(url).path.to_s.delete_suffix("/").present?
    end

    # [vendor, board] when the link is on a known ATS board.
    def board(url)
      if url.match?(GREENHOUSE_EMBED)
        token = Rack::Utils.parse_query(URI.parse(url).query)["for"]
        return [ "greenhouse", token ] if token.present?
      end
      if (match = url.match(WORKDAY))
        tenant, instance, site = match.captures
        return [ "workday", "#{tenant}.#{instance}/#{site}" ]
      end
      if (match = url.match(ORACLE))
        pod, region, site = match.captures
        location = Rack::Utils.parse_query(URI.parse(url).query)["locationId"]
        return [ "oracle", [ "#{pod}.fa.#{region}", site, location.presence ].compact.join("/") ]
      end
      BOARDS.each { |vendor, pattern| (match = url.match(pattern)) and return [ vendor, match[1] ] }
      nil
    end

    def company_from(link, name, actor)
      company = existing(link, name)
      return create!(link, name, actor) unless company

      again = chosen_again(company, link.url, actor)
      note = if company.resolution_status == "resolved"
        "#{company.name} is #{'already ' unless again}watched."
      elsif company.resolution_status == "candidate"
        "#{company.name} has a careers page waiting for you to confirm."
      else
        try_first!(company, link, actor)
        "#{company.name} was on record without a careers page."
      end
      Added.new(company: company, created: false, note: [ again, note ].compact.join(" "), tracked_again: again.present?)
    end

    # A company the operator archived, chosen again by pasting a link to it, or to a role there (4a): tracked again,
    # its roles archived with it left as they are. Returns what was done, in a sentence, or nil.
    def chosen_again(company, url, actor)
      return unless company.dismissed?

      Tracking.track_company!(company, note: "Added by URL: #{url}.", with_roles: false, actor: actor)
      "#{company.name} was archived: tracked again (its archived roles stay archived)."
    end

    def existing(link, name)
      return Company.find_by(domain: link.domain) if link.domain

      by_board = link.board && Company.find_by(board_vendor: link.board[0], board_token: link.board[1])
      by_page = link.page && (Company.find_by(careers_page_url: link.page) || Company.find_by(resolution_candidate_url: link.page))
      by_board || by_page || Company.where("lower(name) = ?", (name.presence || link.name).downcase).first
    end

    def create!(link, name, actor)
      company = Company.new(name: name.presence&.strip || link.name, domain: link.domain, careers_page_url: link.page)
      ApplicationRecord.transaction do
        company.save!
        AuditEvent.record_write!(company, actor: actor, reasoning: "Added by URL: #{link.url}.")
      end
      Added.new(company: company, created: true, note: "#{company.name} added.")
    end

    # A careers page given apart, as it will be watched: an ATS board's own page whichever page of it was pasted,
    # a hosted site's page, or the page itself; never a job board.
    def careers_page(input)
      link = parse(input)
      link.page || link.url
    end

    # The company watched at the careers page given when it was added, set by hand as on its page (4a); one already
    # watched keeps its page, and the note says where.
    def watched_at!(added, url, actor)
      company = added.company
      note = if company.resolution_status == "resolved"
        "#{company.name} keeps its watched page, #{company.careers_page_url}: change it on its page if that is wrong." unless company.careers_page_url == url
      else
        Candidates.set_page!(company, url, reasoning: "Given when added.", actor: actor)
        "Watched at #{url}, as given."
      end
      note ? added.with(note: "#{added.note} #{note}") : added
    end

    # The company on record a link belongs to by its domain or its board, the strong signs (a name alone never is).
    def owner(link)
      return Company.find_by(domain: link.domain) if link.domain

      Company.find_by(board_vendor: link.board[0], board_token: link.board[1]) if link.board
    end

    # A role added or changed at a company the operator chose: tracked (unless `archived:` is fine, as for a role's
    # own page), and the link not another company's on record.
    def at_company!(company, own, archived: false)
      raise ArgumentError, "#{company.name} is archived: track it again before adding a role there" if company.dismissed? && !archived

      other = owner(own)
      return if other.nil? || other == company

      raise ArgumentError, "that link is #{other.name}'s (#{host(own.url).delete_prefix('www.')}), on record: it isn't a role at #{company.name}"
    end

    def elsewhere!(known, company)
      return if known.company == company

      raise ArgumentError, "that role is on record at #{known.company.name}: add it there, or check where you found it"
    end

    def try_first!(company, link, actor)
      return if link.page.blank? || company.careers_page_url == link.page

      ApplicationRecord.transaction do
        company.update!(careers_page_url: link.page)
        AuditEvent.record_write!(company, actor: actor, reasoning: "Added by URL: #{link.url}, the careers page to try first.")
      end
    end

    # --- A role ------------------------------------------------------------------

    # Where the operator found the role: kept, never fetched. A LinkedIn job is kept by its id alone.
    def source_link(input)
      return if input.to_s.strip.empty?

      url = web(input.to_s.strip)
      (id = linkedin_id(url)) ? "https://www.linkedin.com/jobs/view/#{id}" : url
    end

    def linkedin_id(url) = (url[LINKEDIN_JOB, 1] if host(url).end_with?("linkedin.com"))

    # The posting found at the same LinkedIn job, whichever form its link was kept in.
    def by_source(source)
      id = source && linkedin_id(source) or return
      Posting.includes(:company).where("posting_url ~ ?", "linkedin\\.com/jobs/view/([^/?#]*-)?#{id}([/?#]|$)").first
    end

    def by_link(company, url)
      key = link_key(url)
      company.postings.where.not(job_url: nil).find { |posting| link_key(posting.job_url) == key }
    end

    # A role on record by its title alone, only while it has no link of its own to tell it apart.
    def by_title(company, title)
      words = title_words(title)
      company.postings.where(job_url: nil).find { |posting| title_words(posting.role_title) == words }
    end

    def create_role!(company, own, title, location, source, check, actor)
      raise ArgumentError, "give its title: added without a check, nothing reads one from its page" if title.nil? && !check

      posting = company.postings.new(role_title: title || Posting::TITLE_PENDING, location: location.to_s.squish.presence,
                                     job_url: own.url, posting_url: source, tracking: "tracked")
      ApplicationRecord.transaction do
        posting.save!
        AuditEvent.record_write!(posting, actor: actor,
                                          reasoning: "Added by URL: #{own.url}#{" (found at #{source})" if source}.")
      end
      Placed.new(posting: posting, created: true, note: title ? "#{title} tracked." : "Role tracked: its title is read from its own page.")
    end

    # A role already on record, chosen: tracked, with the links it lacked.
    def choose!(posting, own, source, actor)
      was = posting.tracking
      posting.job_url ||= own.url
      posting.posting_url ||= source unless source.nil? || Posting.where.not(id: posting.id).exists?(posting_url: source)
      posting.tracking = "tracked"
      if posting.changed?
        ApplicationRecord.transaction do
          posting.save!
          mark = was == "tracked" ? "Its links filled in." : "Tracked by hand."
          AuditEvent.record_write!(posting, actor: actor, reasoning: "#{mark} Added by URL: #{own.url}.")
        end
      end
      chosen = { "tracked" => "is already tracked", "suggested" => "was suggested: now tracked",
                 "dismissed" => "was archived: tracked again" }.fetch(was)
      Placed.new(posting: posting, created: false, note: "#{posting.role_title} at #{posting.company.name} #{chosen}.")
    end

    # Mirrors workers/verifier/src/verifier/links.py link_key: a link compared as the role it names,
    # a board's other address (SAME_HOSTS) or a Workday page's language aside.
    def link_key(url)
      uri = URI.parse(url)
      host = uri.host.to_s.downcase.delete_prefix("www.")
      host = SAME_HOSTS.fetch(host, host)
      path = uri.path.to_s.chomp("/")
      path = path.sub(%r{\A/[a-z]{2}-[A-Z]{2}(?=/)}, "") if host.end_with?(".myworkdayjobs.com")
      path = path.sub(%r{(?<=/CandidateExperience/)[\w-]+(?=/sites/)}, "-") if host.end_with?(".oraclecloud.com")
      query = URI.decode_www_form(uri.query.to_s).reject { |name, _| name.downcase.start_with?(*TRACKING) }
      route = uri.fragment.to_s.start_with?("/", "!/") ? uri.fragment.chomp("/") : ""
      [ uri.scheme.to_s.downcase, host, path, URI.encode_www_form(query), route ].join("|")
    rescue URI::InvalidURIError, ArgumentError
      url
    end

    # A title's words, as matching compares them: case, accents, and punctuation aside, "Sr." spelled out.
    def title_words(title)
      I18n.transliterate(title.to_s).downcase.scan(/[a-z0-9]+/).map { |word| { "sr" => "senior", "jr" => "junior" }.fetch(word, word) }
    end

    # --- Addresses ---------------------------------------------------------------

    def web(text)
      url = text.match?(%r{\Ahttps?://}i) ? text : "https://#{text}"
      raise ArgumentError, "#{text.inspect} is not a web address or a domain" unless ResultContract.web_url?(url) && host(url).include?(".")

      url
    end

    def host(url) = URI.parse(url).host.to_s.downcase

    # The company's own domain from a host on its site: careers.acme.com is acme.com.
    def company_domain(host)
      labels = host.split(".")
      labels.shift while labels.size > 2 && SITE_LABELS.include?(labels.first)
      labels.join(".")
    end

    # A hosted careers site's own page for the company: acme.gupy.io, or apply.workable.com/acme.
    def hosted_site(url)
      labels = host(url).split(".")
      return "https://#{host(url)}/" if labels.size > 2 && !SITE_LABELS.include?(labels.first)

      first = URI.parse(url).path.split("/").compact_blank.first
      first ? "https://#{host(url)}/#{first}" : url
    end

    # The name a domain was registered under: brasil.fabrikam.com is fabrikam, acme.com.br is acme.
    def registered_name(domain)
      labels = domain.split(".")
      # A country's second level (com.br, co.uk) is part of the suffix, not the name.
      suffix = labels.size > 2 && labels.last.size == 2 && %w[com net org co gov edu ac].include?(labels[-2]) ? 2 : 1
      labels[-(suffix + 1)] || labels.first
    end

    # A name until the operator gives one: the board's, the hosted site's, or the domain's registered name.
    def guessed_name(url, board, domain)
      word =
        if board then board[1].split(/[.\/]/).first
        elsif domain then registered_name(domain)
        else
          labels = host(url).split(".")
          labels.size > 2 && !SITE_LABELS.include?(labels.first) ? labels.first : URI.parse(url).path.split("/").compact_blank.first
        end
      word.to_s.tr("-_", " ").split.map(&:capitalize).join(" ").presence || host(url)
    end
  end
end
