require "rails_helper"

RSpec.describe Verifier::Capture do
  describe ".parse" do
    def parsed(input) = described_class.parse(input).to_h.slice(:page, :domain, :board, :name)

    it "reads a bare domain as the company, with no page to try" do
      expect(parsed("acme-corp.com")).to eq(page: nil, domain: "acme-corp.com", board: nil, name: "Acme Corp")
      expect(parsed("https://www.acme.com/")).to include(page: nil, domain: "acme.com")
    end

    it "names a company after the domain it was registered under, a country's site or suffix aside" do
      expect(parsed("brasil.fabrikam.com")).to include(domain: "brasil.fabrikam.com", name: "Fabrikam")
      expect(parsed("https://www.contoso.com.br/")).to include(domain: "contoso.com.br", name: "Contoso")
    end

    it "reads a careers page on the company's own site, careers subdomains aside" do
      expect(parsed("https://careers.acme.com.br/vagas")).to eq(page: "https://careers.acme.com.br/vagas", domain: "acme.com.br",
                                                                board: nil, name: "Acme")
    end

    it "reads an ATS link as its board, watched at the board's own page whichever page was pasted" do
      expect(parsed("https://job-boards.greenhouse.io/acmecorp/jobs/4012345")).to eq(
        page: "https://job-boards.greenhouse.io/acmecorp", domain: nil, board: %w[greenhouse acmecorp], name: "Acmecorp"
      )
      expect(parsed("https://acme.wd5.myworkdayjobs.com/en-US/External/job/Sao-Paulo/Engineer_R1")).to include(
        page: "https://acme.wd5.myworkdayjobs.com/External", board: [ "workday", "acme.wd5/External" ], name: "Acme"
      )
    end

    it "reads an Oracle Cloud careers link as its site, with the place its page is filtered to" do
      page = "https://emfg.fa.em4.oraclecloud.com/hcmUI/CandidateExperience/pt-BR/sites/CX_4001/jobs?location=Brasil&locationId=300000000314829"
      expect(parsed(page)).to include(board: [ "oracle", "emfg.fa.em4/CX_4001/300000000314829" ], domain: nil,
                                      page: "https://emfg.fa.em4.oraclecloud.com/hcmUI/CandidateExperience/en/sites/CX_4001/jobs?locationId=300000000314829")
      job = "https://emfg.fa.em4.oraclecloud.com/hcmUI/CandidateExperience/pt-BR/sites/CX_4001/job/41966"
      expect(described_class.link_key(job)).to eq(described_class.link_key(job.sub("/pt-BR/", "/en/")))
    end

    it "never takes a hosted careers site's domain for the company's" do
      expect(parsed("https://acme.gupy.io/")).to eq(page: "https://acme.gupy.io/", domain: nil, board: nil, name: "Acme")
      expect(parsed("https://apply.workable.com/acme-labs/")).to include(domain: nil, name: "Acme Labs")
    end

    it "refuses a job board, and what is not an address" do
      expect { described_class.parse("https://www.linkedin.com/jobs/view/123") }.to raise_error(ArgumentError, /on linkedin\.com, a job board/)
      expect { described_class.parse("not a domain") }.to raise_error(ArgumentError, /not a web address/)
      expect { described_class.parse(" ") }.to raise_error(ArgumentError, /paste a company's domain/)
    end
  end

  describe ".role!" do
    def add(**fields) = described_class.role!(**{ link: "https://job-boards.greenhouse.io/acme/jobs/4012345", title: "Sales Engineer" }.merge(fields))

    it "tracks a new role as the operator, with its company added from its link, its board watched at once (4e)" do
      placed = add(location: "São Paulo, Brazil", source: "https://www.linkedin.com/jobs/view/sales-engineer-at-acme-4099887766/?trk=x")

      expect(placed).to have_attributes(created: true, note: "Acme added. Sales Engineer tracked. Its board, " \
                                                             "https://job-boards.greenhouse.io/acme, is watched: read free.")
      expect(placed.posting).to have_attributes(
        role_title: "Sales Engineer", location: "São Paulo, Brazil", tracking: "tracked", verification_state: "pending",
        job_url: "https://job-boards.greenhouse.io/acme/jobs/4012345", posting_url: "https://www.linkedin.com/jobs/view/4099887766"
      )
      expect(placed.posting.company).to have_attributes(name: "Acme", careers_page_url: "https://job-boards.greenhouse.io/acme",
                                                        resolution_status: "resolved", resolution_method: "manual")
      expect(AuditEvent.where(target: placed.posting.company).pluck(:reasoning))
        .to include("Set by hand. Its ATS board, from a role's link (https://job-boards.greenhouse.io/acme/jobs/4012345): watched at once.")
      expect(AuditEvent.find_by!(target: placed.posting)).to have_attributes(
        actor: "human:operator", reasoning: "Added by URL: https://job-boards.greenhouse.io/acme/jobs/4012345 " \
                                            "(found at https://www.linkedin.com/jobs/view/4099887766)."
      )
    end

    it "finds a role already on record by its LinkedIn job, in whatever form its link was kept, and tracks it again" do
      clay = create(:posting, role_title: "Sales Engineer (Remote)", tracking: "dismissed",
                              posting_url: "https://www.linkedin.com/jobs/view/sales-engineer-at-acme-4099887766")

      placed = add(source: "https://www.linkedin.com/jobs/search/?currentJobId=4099887766&keywords=sales")

      expect(placed).to have_attributes(posting: clay, created: false)
      expect(placed.note).to include("was archived: tracked again.")
      expect(clay.reload).to have_attributes(tracking: "tracked", job_url: "https://job-boards.greenhouse.io/acme/jobs/4012345")
      expect(AuditEvent.where(target: clay).sole.reasoning).to start_with("Tracked by hand. Added by URL:")
      expect(Company.count).to eq(1) # its own company: none added
    end

    it "finds a role by its own link, or by its title while it has no link, and never adds it twice" do
      company = create(:company, :resolved, domain: "acme.com")
      suggested = create(:posting, company: company, role_title: "Sales Engineer", tracking: "suggested",
                                   job_url: "https://acme.com/careers/jobs/7?utm_source=linkedin")
      untitled = create(:posting, company: company, role_title: "Sr. Solutions Architect", posting_url: nil)

      expect(add(link: "https://www.acme.com/careers/jobs/7/")).to have_attributes(posting: suggested, note: /was suggested: now tracked/)
      expect(add(link: "https://acme.com/careers/jobs/9", title: "Senior Solutions Architect"))
        .to have_attributes(posting: untitled, note: /is already tracked/)
      expect(untitled.reload.job_url).to eq("https://acme.com/careers/jobs/9")
      expect(Posting.count).to eq(2)
    end

    it "finds a role by the link its board's API gave, pasted from a browser with a language or an older host" do
      contoso = create(:company, :resolved, domain: "contoso.com.br", board_vendor: "workday", board_token: "contoso.wd1/contoso",
                                            board_overlap: 1.0, board_evidence: "Lists the roles.", board_confirmed_at: 1.day.ago)
      learned = create(:posting, company: contoso, role_title: "Sales Engineer", tracking: "suggested",
                                 job_url: "https://contoso.wd1.myworkdayjobs.com/contoso/job/So-Paulo-Brazil/Sales-Engineer_R10482")

      placed = add(link: "https://contoso.wd1.myworkdayjobs.com/en-US/contoso/job/So-Paulo-Brazil/Sales-Engineer_R10482", title: "")

      expect(placed.posting).to eq(learned)
      expect(described_class.link_key("https://boards.greenhouse.io/acme/jobs/1"))
        .to eq(described_class.link_key("https://job-boards.greenhouse.io/acme/jobs/1"))
    end

    it "refuses a job board as the role's own page" do
      expect { add(link: "https://www.linkedin.com/jobs/view/4099887766") }.to raise_error(ArgumentError, /can go in where you found it/)
    end

    it "takes a role without a title when a check follows, to be named by its own page then, never matched by title" do
      untitled = create(:posting, company: create(:company, domain: "acme.com"), role_title: Posting::TITLE_PENDING, posting_url: nil)

      placed = add(link: "https://acme.com/careers/jobs/12", title: " ", check: true)

      expect(placed).to have_attributes(created: true, note: "Role tracked: its title is read from its own page.")
      expect(placed.posting).to have_attributes(role_title: Posting::TITLE_PENDING, title_pending?: true)
      expect(placed.posting).not_to eq(untitled)
    end

    it "takes a role on the company's own site at the company's domain, its careers page left to be found" do
      placed = add(link: "https://careers.acme.com.br/vagas/123-engenheiro", title: "Engenheiro de Vendas")

      expect(placed.posting.company).to have_attributes(domain: "acme.com.br", careers_page_url: nil)
    end

    # 4a: adding reads nothing unless asked, so a role added without a check needs its title; nothing is written when
    # it is refused, not even the company its link would have added.
    it "needs a title without a check, and writes nothing without one, not even its company" do
      expect { add(link: "https://careers.newco.example/jobs/1", title: " ") }
        .to raise_error(ArgumentError, "give its title: added without a check, nothing reads one from its page")
      expect([ Company.count, Posting.count, AuditEvent.count ]).to eq([ 0, 0, 0 ])

      known = create(:posting, company: create(:company, domain: "acme.com"), job_url: "https://acme.com/careers/jobs/7", tracking: "suggested")
      expect(add(link: "https://acme.com/careers/jobs/7", title: "").posting).to eq(known) # one on record needs none
    end

    describe "from a company's page" do
      let(:acme) { create(:company, :resolved, name: "Acme", domain: "acme.com") }

      it "adds it at that company, whatever name its link would guess" do
        placed = add(link: "https://apply.workable.com/acme-labs/j/1A2B3C/", title: "Sales Engineer", company: acme)

        expect(placed).to have_attributes(created: true, note: "Sales Engineer tracked.")
        expect(placed.posting.company).to eq(acme)
        expect(Company.count).to eq(1)
      end

      it "refuses at an archived company, a link on another company's site or board, or a role on record elsewhere" do
        contoso = create(:company, :resolved, name: "Contoso", domain: "contoso.com")
        create(:company, :resolved, name: "Fabrikam", board_vendor: "lever", board_token: "fabrikam", board_overlap: 1.0,
                                    board_evidence: "Lists the roles.", board_confirmed_at: 1.day.ago)
        elsewhere = create(:posting, company: contoso, posting_url: "https://www.linkedin.com/jobs/view/4099887766")

        expect { add(link: "https://contoso.com/jobs/1", company: acme) }
          .to raise_error(ArgumentError, "that link is Contoso's (contoso.com), on record: it isn't a role at Acme")
        expect { add(link: "https://jobs.lever.co/fabrikam/0f1e", company: acme) }.to raise_error(ArgumentError, /is Fabrikam's \(jobs\.lever\.co\), on record/)
        expect { add(link: "https://acme.com/jobs/2", source: "https://www.linkedin.com/jobs/view/4099887766", company: acme) }
          .to raise_error(ArgumentError, "that role is on record at Contoso: add it there, or check where you found it")
        Verifier::Tracking.dismiss_company!(acme, note: "Pausing.")
        expect { add(link: "https://acme.com/jobs/3", company: acme) }
          .to raise_error(ArgumentError, "Acme is archived: track it again before adding a role there")
        expect(Posting.all).to eq([ elsewhere ])
      end
    end
  end

  # 4e, add by link: the company's website beside an ATS link, its board watched at once, and an ATS posting shown on a
  # careers page added as that posting.
  describe ".role!, adding by link" do
    def add(**fields) = described_class.role!(**{ link: "https://job-boards.greenhouse.io/acmeinc/jobs/4012345", check: true }.merge(fields))

    it "names a new company by the website given beside an ATS link, and keeps it as its domain" do
      placed = add(website: "https://www.acme.com/about")

      expect(placed.posting.company).to have_attributes(name: "Acme", domain: "acme.com", careers_page_url: "https://job-boards.greenhouse.io/acmeinc",
                                                        resolution_status: "resolved")
      expect(placed.note).to start_with("Acme added. Role tracked")
    end

    it "finds the company by the website's domain, or by its board, the website then kept as its domain" do
      by_domain = create(:company, :resolved, name: "Acme Inc", domain: "acme.com")
      expect(add(website: "acme.com").posting.company).to eq(by_domain)
      expect(by_domain.reload.careers_page_url).to eq("https://acme.com/careers") # watched already: kept

      by_board = create(:company, :without_domain, name: "Contoso", careers_page_url: "https://jobs.ashbyhq.com/contoso")
      placed = add(link: "https://jobs.ashbyhq.com/contoso/7d1e2f3a-0b4c-4d5e-9f60-1a2b3c4d5e6f", website: "contoso.com")
      expect(placed.posting.company).to eq(by_board)
      expect(placed.note).to include("Its website: contoso.com.")
      expect(by_board.reload.domain).to eq("contoso.com")
      expect(AuditEvent.where(target: by_board).pluck(:reasoning)).to include("Its website, given with a role's link: contoso.com.")
    end

    it "sets the website aside for a link on the company's own site, and refuses one that isn't a company's site" do
      expect(add(link: "https://careers.fabrikam.com/jobs/1", website: "fabrikam.io").posting.company.domain).to eq("fabrikam.com")
      expect { add(website: "https://jobs.lever.co/acme") }.to raise_error(ArgumentError, /give the company's own website: jobs\.lever\.co hosts/)
      expect { add(website: "linkedin.com/company/acme") }.to raise_error(ArgumentError, /a job board/)
    end

    it "refuses a board on record as another company's, with the website of a company it isn't" do
      create(:company, :resolved, name: "Contoso", domain: "contoso.com", careers_page_url: "https://job-boards.greenhouse.io/acmeinc")
      create(:company, name: "Acme", domain: "acme.com")

      expect { add(website: "acme.com") }
        .to raise_error(ArgumentError, "that link is on Contoso's board, on record; the website given is Acme's")
      expect(Posting.count).to eq(0)
    end

    it "watches the board only of a company not watched yet, never one waiting for the operator, and never as the assistant" do
      waiting = create(:company, :resolution_candidate, name: "Litware", domain: "litware.com")
      expect(add(link: "https://jobs.lever.co/litware/0f1e", company: waiting).note).not_to include("is watched")
      expect(waiting.reload.resolution_status).to eq("candidate")

      unwatched = create(:company, name: "Northwind", domain: "northwind.com")
      placed = as_agent("agent:assistant", scopes: %w[watchlist:curate]) do
        described_class.role!(link: "https://jobs.lever.co/northwind/0f1e", title: "Sales Engineer", company: unwatched,
                              note: "On the operator's word.", actor: "agent:assistant")
      end
      expect(placed.note).not_to include("is watched")
      expect(unwatched.reload.resolution_status).to be_nil
    end

    it "adds a posting shown on a careers page as that posting, once its company's board is on record" do
      company = create(:company, :resolved, name: "Acme", domain: "acme.com", careers_page_url: "https://job-boards.greenhouse.io/acmeinc")

      placed = add(link: "https://www.acme.com/careers/?gh_jid=4012345&gh_src=x", title: "Sales Engineer")

      expect(placed.posting).to have_attributes(company: company, job_url: "https://job-boards.greenhouse.io/acmeinc/jobs/4012345")
      expect(placed.note).to eq("Sales Engineer tracked. Its link shows a Greenhouse posting: added as that posting, " \
                                "https://job-boards.greenhouse.io/acmeinc/jobs/4012345.")
      expect(AuditEvent.find_by!(target: placed.posting).reasoning)
        .to eq("Added by URL: https://job-boards.greenhouse.io/acmeinc/jobs/4012345. Pasted as https://www.acme.com/careers/?gh_jid=4012345&gh_src=x.")
      expect(add(link: "https://acme.com/careers?gh_jid=4012345").posting).to eq(placed.posting) # never added twice

      board = create(:company, :resolved, name: "Contoso", domain: "contoso.com", board_vendor: "ashby", board_token: "contoso",
                                          board_confirmed_at: 1.day.ago)
      shown = add(link: "https://contoso.com/careers?ashby_jid=7d1e2f3a-0b4c-4d5e-9f60-1a2b3c4d5e6f")
      expect(shown.posting).to have_attributes(company: board, job_url: "https://jobs.ashbyhq.com/contoso/7d1e2f3a-0b4c-4d5e-9f60-1a2b3c4d5e6f")
    end

    it "keeps a careers-page link whose posting's board isn't on record, its careers page to try first, and says what follows" do
      placed = add(link: "https://www.fabrikam.com/careers/?ashby_jid=7d1e2f3a-0b4c-4d5e-9f60-1a2b3c4d5e6f&utm_source=x")

      expect(placed.posting.job_url).to eq("https://www.fabrikam.com/careers/?ashby_jid=7d1e2f3a-0b4c-4d5e-9f60-1a2b3c4d5e6f&utm_source=x")
      expect(placed.posting.company).to have_attributes(domain: "fabrikam.com", careers_page_url: "https://www.fabrikam.com/careers/",
                                                        resolution_status: nil)
      expect(placed.note).to end_with("Its link shows an Ashby posting from a board not on record yet: its first check finds the posting " \
                                      "on the careers page, and its own page moves there; its description is read from there.")
      expect(described_class.embedded("https://acme.com/careers?gh_jid=abc")).to be_nil # not a Greenhouse id
      expect(described_class.embedded("https://job-boards.greenhouse.io/acme/jobs/1?gh_jid=4012345")).to be_nil # on the ATS itself
    end
  end

  # 4a: the role's own page at the employer, set by the operator from the role's page.
  describe ".own_page!" do
    let(:acme) { create(:company, :resolved, name: "Acme", domain: "acme.com") }
    let(:role) { create(:posting, company: acme, role_title: "Sales Engineer", job_url: "https://acme.com/jobs/1") }

    it "sets it as the operator, with their note, the link each check tries first" do
      described_class.own_page!(role, "acme.com/careers/jobs/9", note: "The old link moved.")

      expect(role.reload.job_url).to eq("https://acme.com/careers/jobs/9")
      expect(role.audit_events.sole).to have_attributes(actor: AuditEvent::OPERATOR, changes_made: { "job_url" => [ "https://acme.com/jobs/1", "https://acme.com/careers/jobs/9" ] },
                                                        reasoning: "Its own page set by hand. The old link moved.")
    end

    # 4e: a careers-page link showing the posting from its ATS is the posting, once the company's board is on record.
    it "sets the posting a careers-page link shows, from the company's board on record" do
      acme.update!(board_vendor: "greenhouse", board_token: "acmeinc", board_confirmed_at: 1.day.ago)

      described_class.own_page!(role, "https://acme.com/careers?gh_jid=4012345")

      expect(role.reload.job_url).to eq("https://job-boards.greenhouse.io/acmeinc/jobs/4012345")
    end

    it "refuses a job board, another company's site, the page it has, and another role's" do
      create(:company, :resolved, name: "Contoso", domain: "contoso.com")
      create(:posting, company: acme, role_title: "Recruiter", job_url: "https://acme.com/jobs/2")

      expect { described_class.own_page!(role, "https://www.linkedin.com/jobs/view/4099887766") }.to raise_error(ArgumentError, /on linkedin\.com, a job board/)
      expect { described_class.own_page!(role, "https://contoso.com/jobs/1") }.to raise_error(ArgumentError, /is Contoso's \(contoso\.com\), on record/)
      expect { described_class.own_page!(role, "https://www.acme.com/jobs/1/") }.to raise_error(ArgumentError, "that is already its own page")
      expect { described_class.own_page!(role, "https://acme.com/jobs/2") }
        .to raise_error(ArgumentError, "that link is Recruiter's own page, on record at Acme")
      expect(role.audit_events).to be_empty
    end
  end

  describe ".company!" do
    it "adds a company as the operator, keeping the page given to try first" do
      added = described_class.company!("https://careers.acme.com/open-roles", name: "Acme Inc")

      expect(added).to have_attributes(created: true, note: "Acme Inc added.")
      expect(added.company).to have_attributes(name: "Acme Inc", domain: "acme.com", resolution_status: nil,
                                               careers_page_url: "https://careers.acme.com/open-roles")
      event = AuditEvent.find_by!(target: added.company)
      expect(event).to have_attributes(actor: "human:operator", action: "create",
                                       reasoning: "Added by URL: https://careers.acme.com/open-roles.")
    end

    it "finds a company already on record by its domain, its board, or its page, and never adds it twice" do
      watched = create(:company, :resolved, domain: "acme.com")
      on_board = create(:company, :resolved, board_vendor: "lever", board_token: "beta", board_overlap: 1.0,
                                             board_evidence: "Lists the roles.", board_confirmed_at: 1.day.ago)

      expect(described_class.company!("acme.com")).to have_attributes(company: watched, created: false, note: /already watched/)
      expect(described_class.company!("https://jobs.lever.co/beta/0f1e")).to have_attributes(company: on_board, created: false)
      expect(Company.count).to eq(2)
    end

    it "gives a company on record without a page the one pasted, to try first" do
      bare = create(:company, domain: "gamma.com", resolution_status: "failed", resolution_failure: "not_found")

      described_class.company!("https://gamma.com/jobs")

      expect(bare.reload.careers_page_url).to eq("https://gamma.com/jobs")
      expect(AuditEvent.find_by!(target: bare).reasoning).to eq("Added by URL: https://gamma.com/jobs, the careers page to try first.")
    end

    # 4a: a careers page given when the company is added is watched as given, set by hand, so it is watched with no
    # read; a company already watched keeps its page.
    it "watches a company at the careers page given with it, as set by hand; one already watched keeps its own" do
      added = described_class.company!("acme.com", page: "https://jobs.lever.co/acme/0f1e2d")

      expect(added.note).to eq("Acme added. Watched at https://jobs.lever.co/acme, as given.")
      expect(added.company.reload).to have_attributes(careers_page_url: "https://jobs.lever.co/acme", resolution_status: "resolved",
                                                      resolution_method: "manual")
      expect(Company.watched).to include(added.company)
      expect(AuditEvent.where(target: added.company).pluck(:reasoning)).to contain_exactly("Added by URL: https://acme.com.", "Set by hand. Given when added.")

      expect(described_class.company!("acme.com", page: "https://acme.com/careers").note)
        .to eq("Acme is already watched. Acme keeps its watched page, https://jobs.lever.co/acme: change it on its page if that is wrong.")
      expect { described_class.company!("contoso.com", page: "https://www.linkedin.com/company/contoso") }.to raise_error(ArgumentError, /job board/)
      expect(Company.count).to eq(1)
    end

    # 4a: pasting a link is choosing it, so an archived company pasted, or a role there, is tracked again; the roles
    # archived with it stay archived.
    it "tracks an archived company again when it is pasted, or a role at it, its archived roles left archived" do
      acme = create(:company, :resolved, name: "Acme", domain: "acme.com")
      old_role = create(:posting, company: acme, role_title: "Recruiter")
      Verifier::Tracking.dismiss_company!(acme, note: "Pausing.")

      added = described_class.company!("acme.com")

      expect(added).to have_attributes(company: acme, created: false, tracked_again: true,
                                       note: "Acme was archived: tracked again (its archived roles stay archived). Acme is watched.")
      expect(acme.reload.tracking).to eq("tracked")
      expect(AuditEvent.where(target: acme).order(:occurred_at).last.reasoning).to eq("Tracked by hand. Added by URL: https://acme.com.")
      expect(old_role.reload.tracking).to eq("dismissed")

      Verifier::Tracking.dismiss_company!(acme, note: "Pausing again.")
      placed = described_class.role!(link: "https://acme.com/careers/jobs/7", title: "Solutions Engineer")
      expect(placed.note).to start_with("Acme was archived: tracked again").and end_with("Solutions Engineer tracked.")
      expect(acme.reload.tracking).to eq("tracked")
    end
  end
end
