require "rails_helper"

# Companies the operator's own Claude client proposes (4b): added as "suggested", with why, under a credential holding
# companies:suggest; what each one's board lists is the app's own free read, never the client's word; and why it may
# fit is the operator's business, held by the audit log as a hash alone.
RSpec.describe Verifier::Proposals do
  let!(:profile) { SearchProfile.create!(titles: [ "Solutions Engineer" ]) }

  # Stands in for Verifier::Worker, run with no API key: records what it was asked, and hands back the results given.
  let(:worker_class) do
    Class.new do
      attr_reader :asked

      def initialize(results) = @results = results

      def free? = true

      def run(targets, command:, flags: [])
        @asked = { targets: targets, command: command, flags: flags }
        Verifier::Worker::Run.new(dir: Pathname.new("tmp/verifier/20261106T120000Z-#{command}"), results: @results, stopped: nil)
      end
    end
  end

  let(:nothing_read) { worker_class.new([]) }

  def candidate(**given)
    described_class::Candidate.new(name: "Fabrikam", domain: "fabrikam.example", why: "Sells to revenue teams in Brazil.",
                                   source: "job_board_search", query: '"solutions engineer" site:jobs.ashbyhq.com',
                                   links: [ "https://jobs.ashbyhq.com/fabrikam/123" ], **given)
  end

  def propose(*candidates, finder: nothing_read, **options)
    as_agent("agent:assistant", scopes: %w[companies:suggest]) { described_class.propose!(candidates, finder: finder, profile: profile, **options) }
  end

  def board_read(outcome: "resolved", count: 3, reason: nil)
    { "kind" => "resolution", "target_id" => "c0", "outcome" => outcome, "careers_page_url" => "https://jobs.ashbyhq.com/fabrikam",
      "checks" => [ { "url" => "https://jobs.ashbyhq.com/fabrikam", "checked_at" => "2026-11-06T12:00:00+00:00", "outcome" => "ok",
                      "step" => "proposal", "listing_count" => count, "reason" => reason,
                      "listings" => Array.new(count) { |n| { "title" => "Role #{n}" } } } ] }
  end

  it "proposes a company, not tracked, with why, where it was found and what its board listed, read free" do
    finder = worker_class.new([ board_read ])
    weigher = worker_class.new([ { "kind" => "suggestion", "target_id" => "c0", "roles" => [ { "suggested" => true }, { "suggested" => false } ] } ])

    outcome = propose(candidate, finder: finder, weigher: weigher, reported_model: "claude-opus-5-5").sole

    expect(outcome).to have_attributes(status: "created", note: "Fabrikam proposed.")
    expect(outcome.company).to have_attributes(name: "Fabrikam", domain: "fabrikam.example", tracking: "suggested",
                                               careers_page_url: nil, resolution_status: nil)
    expect(outcome.company.proposal).to eq(
      "why" => "Sells to revenue teams in Brazil.", "source" => "job_board_search", "query" => '"solutions engineer" site:jobs.ashbyhq.com',
      "links" => [ "https://jobs.ashbyhq.com/fabrikam/123" ], "written_by" => "agent:assistant", "reported_model" => "claude-opus-5-5",
      "seen" => { "board" => "https://jobs.ashbyhq.com/fabrikam", "roles" => 3, "fitting" => 1, "owner" => "confirmed",
                  "read_at" => "2026-11-06T12:00:00+00:00" }
    )
    # The board among its links read through its own page, then weighed against the profile's titles: no role on record.
    expect(finder.asked).to include(command: "own_board", targets: [ hash_including(url: "https://jobs.ashbyhq.com/fabrikam", name: "Fabrikam") ])
    expect(weigher.asked).to include(command: "suggest", targets: [ hash_including(postings: [], profile: profile.to_worker) ])
    expect(weigher.asked[:targets].sole[:listings].size).to eq(3)
  end

  it "keeps why it may fit off the audit log, as a hash, under the client's credential for companies:suggest" do
    company = propose(candidate).sole.company

    event = AuditEvent.find_by!(target: company)
    expect(event).to have_attributes(actor: "agent:assistant", action: "create",
                                     reasoning: "Proposed by the operator's own Claude client, found by a job-board search. " \
                                                "Why it may fit is kept on the company alone.")
    expect(event.changes_made.dig("proposal", "why")).to eq([ nil, Resume.digest("Sells to revenue teams in Brazil.") ])
    expect(event.changes_made.to_json).not_to include("revenue teams")
    expect(event.changes_made["tracking"]).to eq([ nil, "suggested" ])
    expect(event.credential.reload).to have_attributes(scopes: %w[companies:suggest], status: "revoked")
  end

  it "refuses a company on record, found as Add by URL finds it, saying in which state; and saves the rest" do
    create(:company, name: "Tailspin", domain: "tailspin.example")
    create(:company, name: "Northwind", domain: "northwind.example", tracking: "dismissed")
    create(:company, name: "Litware", domain: nil, board_vendor: "lever", board_token: "litware", board_confirmed_at: Time.current)
    create(:company, name: "Woodgrove", domain: "woodgrove.example")
    before = AuditEvent.count

    outcomes = propose(candidate(name: "Tailspin", domain: "careers.tailspin.example", links: []),
                       candidate(name: "Northwind", domain: "northwind.example", links: []),
                       candidate(name: "Litware", domain: "litware.example", link: "https://jobs.lever.co/litware", links: []),
                       candidate(name: "Woodgrove", domain: "woodgrove.io", links: []),
                       candidate(links: []))

    expect(outcomes.map { |outcome| [ outcome.status, outcome.note ] }).to eq([
      [ "refused", "Tailspin: Tailspin is on record, tracked already" ],
      [ "refused", "Northwind: Northwind is on record, archived (a proposal declined is never proposed again)" ],
      [ "refused", "Litware: Litware is on record, tracked already" ],
      [ "refused", "Woodgrove: Woodgrove is on record, tracked already" ],
      [ "created", "Fabrikam proposed." ]
    ])
    expect(AuditEvent.count - before).to eq(1)
  end

  it "refreshes the why of a company proposed already, keeping its name" do
    proposed = create(:company, :proposed, name: "Fabrikam", domain: "fabrikam.example")
    old_why = proposed.proposal["why"]

    outcome = later { propose(candidate(name: "Fabrikam Ltd", why: "Opened an office in São Paulo.", links: [])).sole }

    expect(outcome).to have_attributes(status: "refreshed", company: proposed, note: "Fabrikam was proposed already: its why is brought up to date.")
    expect(proposed.reload).to have_attributes(name: "Fabrikam", tracking: "suggested")
    expect(proposed.proposal["why"]).to eq("Opened an office in São Paulo.")
    event = AuditEvent.where(target: proposed).order(:occurred_at).last
    expect(event.reasoning).to start_with("Proposal refreshed by the operator's own Claude client")
    expect(event.changes_made.dig("proposal", "why")).to eq([ Resume.digest(old_why), Resume.digest("Opened an office in São Paulo.") ])
  end

  it "says what a candidate lacks, writing nothing for it; and takes at most ten a call" do
    notes = propose(candidate(why: " "), candidate(source: "rumour"), candidate(domain: nil), candidate(domain: "fabrikam.recruitee.com"),
                    candidate(link: "https://www.linkedin.com/jobs/view/4012345678"), candidate(name: "")).map(&:note)

    expect(notes).to eq([
      "Fabrikam: say why it may fit",
      "Fabrikam: say where it was found: one of job_board_search, lookalike, news, list, linkedin, other",
      "Fabrikam: give the company's own domain (acme.com)",
      "Fabrikam: fabrikam.recruitee.com is a careers site's address, not the company's own domain",
      "Fabrikam: that link is on linkedin.com, a job board: its links are never read. Paste the employer's domain or careers page instead.",
      "A company: give the company's name"
    ])
    expect(Company.where(name: "Fabrikam")).to be_empty
    expect { propose(*Array.new(11) { candidate }) }.to raise_error(ArgumentError, "at most 10 companies a call")
  end

  it "is the client's write alone, and companies:suggest writes nothing else" do
    expect { described_class.propose!([ candidate ], finder: nothing_read) }.to raise_error(Authority::Denied)

    proposed = create(:company, :proposed, name: "Contoso", domain: "contoso.example")
    tracked = create(:company, name: "Acme", domain: "acme.example", proposal: { "why" => "On record." })
    as_agent("agent:assistant", scopes: %w[companies:suggest]) do
      expect { Company.create!(name: "Tracked Co", domain: "tracked.example", proposal: { "why" => "x" }) }.to raise_error(Authority::Denied)
      expect { Company.create!(name: "Paged Co", domain: "paged.example", tracking: "suggested", proposal: { "why" => "x" }, careers_page_url: "https://paged.example/jobs") }
        .to raise_error(Authority::Denied)
      expect { proposed.update!(name: "Contoso Ltd") }.to raise_error(Authority::Denied)
      expect { tracked.update!(proposal: { "why" => "Refreshed." }) }.to raise_error(Authority::Denied)
    end
    # Nor may the importer write a proposal.
    as_agent("agent:clay_importer") do
      expect { Company.create!(name: "Imported Co", domain: "imported.example", proposal: { "why" => "x" }) }.to raise_error(Authority::Denied)
    end
    expect(AuditEvent.where(action: "denied").count).to eq(6)
  end
end
