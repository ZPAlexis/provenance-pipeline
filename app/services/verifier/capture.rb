module Verifier
  # Adding to the watch list by hand (1.5d): a company from its domain, its
  # careers page, or its ATS board. Only the operator adds, and each addition is
  # audited as theirs. Nothing is fetched here: the first read is a check now,
  # which finds the careers page first when there is none, trying the link given.
  module Capture
    ACTOR = AuditEvent::OPERATOR

    # Job boards list other companies' roles, and are never fetched: never a careers page.
    # A job board's link can sit beside a role the operator adds, as where it was found.
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

    # Careers sites hosted for many companies: the host names the vendor, never the company.
    HOSTED = /(?:\A|\.)(?:gupy\.io|recruitee\.com|teamtailor\.com|bamboohr\.com|breezy\.hr|workable\.com|
              smartrecruiters\.com|personio\.(?:de|com)|jobvite\.com|icims\.com|taleo\.net|successfactors\.(?:com|eu)|
              pinpointhq\.com|applytojob\.com|comeet\.com|freshteam\.com|zohorecruit\.com|rippling\.com|
              myworkdayjobs\.com|greenhouse\.io|lever\.co|ashbyhq\.com)\z/x
    # Leading labels that name a careers site, not the company: careers.acme.com is acme.com.
    SITE_LABELS = %w[www careers career jobs job work apply join talent boards job-boards].freeze

    # What a pasted link or domain says: where the company's roles may be listed, and who it is.
    Link = Data.define(:url, :page, :domain, :board, :name)
    Added = Data.define(:company, :created, :note)

    module_function

    # The company the operator pasted, found or added. A page given (a careers page, an ATS
    # board) is kept as the one to try first while the company has no watched page.
    def company!(input, name: nil, actor: ACTOR)
      link = parse(input)
      company = existing(link, name)
      return create!(link, name, actor) unless company

      if company.resolution_status == "resolved"
        Added.new(company: company, created: false, note: "#{company.name} is already watched.")
      elsif company.resolution_status == "candidate"
        Added.new(company: company, created: false, note: "#{company.name} has a careers page waiting for you to confirm.")
      else
        try_first!(company, link, actor)
        Added.new(company: company, created: false, note: "#{company.name} was on record without a careers page.")
      end
    end

    def parse(input)
      text = input.to_s.strip
      raise ArgumentError, "paste a company's domain, careers page, or ATS board" if text.empty?

      url = text.match?(%r{\Ahttps?://}i) ? text : "https://#{text}"
      raise ArgumentError, "#{text.inspect} is not a web address or a domain" unless ResultContract.web_url?(url) && host(url).include?(".")

      if host(url).match?(JOB_BOARDS)
        raise ArgumentError, "#{host(url)} is a job board: its links are never read. Paste the employer's domain " \
                             "or careers page instead."
      end

      board = board(url)
      hosted = host(url).match?(HOSTED)
      # A board is watched at its own page, whichever of its pages was pasted; a bare domain names no page.
      page = board ? Resolution.board_url(*board) : (url if hosted || URI.parse(url).path.to_s.delete_suffix("/").present?)
      domain = (company_domain(host(url)) unless hosted)
      Link.new(url: url, page: page, domain: domain, board: board, name: guessed_name(url, board, domain))
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
      BOARDS.each { |vendor, pattern| (match = url.match(pattern)) and return [ vendor, match[1] ] }
      nil
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

    def try_first!(company, link, actor)
      return if link.page.blank? || company.careers_page_url == link.page

      ApplicationRecord.transaction do
        company.update!(careers_page_url: link.page)
        AuditEvent.record_write!(company, actor: actor, reasoning: "Added by URL: #{link.url}, the careers page to try first.")
      end
    end

    def host(url) = URI.parse(url).host.to_s.downcase

    # The company's own domain from a host on its site: careers.acme.com is acme.com.
    def company_domain(host)
      labels = host.split(".")
      labels.shift while labels.size > 2 && SITE_LABELS.include?(labels.first)
      labels.join(".")
    end

    # The name a domain was registered under: brasil.arcelormittal.com is arcelormittal, acme.com.br is acme.
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
