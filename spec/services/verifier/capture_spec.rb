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
