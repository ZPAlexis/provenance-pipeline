require "rails_helper"

RSpec.describe Verifier::Capture do
  describe ".parse" do
    def parsed(input) = described_class.parse(input).to_h.slice(:page, :domain, :board, :name)

    it "reads a bare domain as the company, with no page to try" do
      expect(parsed("acme-corp.com")).to eq(page: nil, domain: "acme-corp.com", board: nil, name: "Acme Corp")
      expect(parsed("https://www.acme.com/")).to include(page: nil, domain: "acme.com")
    end

    it "names a company after the domain it was registered under, a country's site or suffix aside" do
      expect(parsed("brasil.arcelormittal.com")).to include(domain: "brasil.arcelormittal.com", name: "Arcelormittal")
      expect(parsed("https://www.zendesk.com.br/")).to include(domain: "zendesk.com.br", name: "Zendesk")
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

    it "never takes a hosted careers site's domain for the company's" do
      expect(parsed("https://acme.gupy.io/")).to eq(page: "https://acme.gupy.io/", domain: nil, board: nil, name: "Acme")
      expect(parsed("https://apply.workable.com/acme-labs/")).to include(domain: nil, name: "Acme Labs")
    end

    it "refuses a job board, and what is not an address" do
      expect { described_class.parse("https://www.linkedin.com/jobs/view/123") }.to raise_error(ArgumentError, /linkedin\.com is a job board/)
      expect { described_class.parse("not a domain") }.to raise_error(ArgumentError, /not a web address/)
      expect { described_class.parse(" ") }.to raise_error(ArgumentError, /paste a company's domain/)
    end
  end

  describe ".role!" do
    def add(**fields) = described_class.role!(**{ link: "https://job-boards.greenhouse.io/acme/jobs/4012345", title: "Sales Engineer" }.merge(fields))

    it "tracks a new role as the operator, with its company added from its link, the board to try first" do
      placed = add(location: "São Paulo, Brazil", source: "https://www.linkedin.com/jobs/view/sales-engineer-at-acme-4099887766/?trk=x")

      expect(placed).to have_attributes(created: true, note: "Acme added. Sales Engineer tracked.")
      expect(placed.posting).to have_attributes(
        role_title: "Sales Engineer", location: "São Paulo, Brazil", tracking: "tracked", verification_state: "pending",
        job_url: "https://job-boards.greenhouse.io/acme/jobs/4012345", posting_url: "https://www.linkedin.com/jobs/view/4099887766"
      )
      expect(placed.posting.company).to have_attributes(name: "Acme", careers_page_url: "https://job-boards.greenhouse.io/acme")
      expect(AuditEvent.find_by!(target: placed.posting)).to have_attributes(
        actor: "human:operator", reasoning: "Added by URL: https://job-boards.greenhouse.io/acme/jobs/4012345 "                                             "(found at https://www.linkedin.com/jobs/view/4099887766)."
      )
    end

    it "finds a role already on record by its LinkedIn job, in whatever form its link was kept, and tracks it again" do
      clay = create(:posting, role_title: "Sales Engineer (Remote)", tracking: "dismissed",
                              posting_url: "https://www.linkedin.com/jobs/view/sales-engineer-at-acme-4099887766")

      placed = add(source: "https://www.linkedin.com/jobs/search/?currentJobId=4099887766&keywords=sales")

      expect(placed).to have_attributes(posting: clay, created: false)
      expect(placed.note).to end_with("was dismissed: tracked again.")
      expect(clay.reload).to have_attributes(tracking: "tracked", job_url: "https://job-boards.greenhouse.io/acme/jobs/4012345")
      expect(AuditEvent.where(target: clay).last.reasoning).to start_with("Tracked by hand. Added by URL:")
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
      zendesk = create(:company, :resolved, domain: "zendesk.com.br", board_vendor: "workday", board_token: "zendesk.wd1/zendesk",
                                            board_overlap: 1.0, board_evidence: "Lists the roles.", board_confirmed_at: 1.day.ago)
      learned = create(:posting, company: zendesk, role_title: "Sales Engineer", tracking: "suggested",
                                 job_url: "https://zendesk.wd1.myworkdayjobs.com/zendesk/job/So-Paulo-Brazil/Sales-Engineer_R35148")

      placed = add(link: "https://zendesk.wd1.myworkdayjobs.com/en-US/zendesk/job/So-Paulo-Brazil/Sales-Engineer_R35148", title: "")

      expect(placed.posting).to eq(learned)
      expect(described_class.link_key("https://boards.greenhouse.io/acme/jobs/1"))
        .to eq(described_class.link_key("https://job-boards.greenhouse.io/acme/jobs/1"))
    end

    it "refuses a job board as the role's own page" do
      expect { add(link: "https://www.linkedin.com/jobs/view/4099887766") }.to raise_error(ArgumentError, /can go in where you found it/)
    end

    it "takes a role without a title, to be named by its own page at its first check, never matched by title" do
      untitled = create(:posting, company: create(:company, domain: "acme.com"), role_title: Posting::TITLE_PENDING, posting_url: nil)

      placed = add(link: "https://acme.com/careers/jobs/12", title: " ")

      expect(placed).to have_attributes(created: true, note: "Role tracked: its title is read from its own page.")
      expect(placed.posting).to have_attributes(role_title: Posting::TITLE_PENDING, title_pending?: true)
      expect(placed.posting).not_to eq(untitled)
    end

    it "takes a role on the company's own site at the company's domain, its careers page left to be found" do
      placed = add(link: "https://careers.acme.com.br/vagas/123-engenheiro", title: "Engenheiro de Vendas")

      expect(placed.posting.company).to have_attributes(domain: "acme.com.br", careers_page_url: nil)
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
  end
end
