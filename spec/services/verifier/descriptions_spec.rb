require "rails_helper"

RSpec.describe Verifier::Descriptions do
  let!(:company) { create(:company, :resolved, name: "Acme", domain: "acme.example") }
  let!(:role) do
    create(:posting, company: company, role_title: "Sales Engineer", tracking: "tracked",
                     job_url: "https://job-boards.greenhouse.io/acme/jobs/4012345")
  end

  # Stands in for Verifier::Worker: records what it was asked to run, and hands back the results given.
  let(:worker_class) do
    Class.new do
      attr_reader :asked

      def initialize(results) = @results = results

      def run(targets, command:)
        @asked = { targets: targets, command: command }
        Verifier::Worker::Run.new(dir: Pathname.new("tmp/verifier/20261016T120000Z-describe"), results: @results, stopped: nil)
      end
    end
  end

  def described(text, at: "2026-10-16T12:00:00+00:00", posting: role, **fields)
    { "kind" => "description", "target_id" => posting.id, "url" => posting.job_url, "outcome" => "ok",
      "read_via" => "ats_api:greenhouse", "text" => text, "content_hash" => "sha256:#{Digest::SHA256.hexdigest(text)}",
      "checked_at" => at, **fields }
  end

  def read(*results, postings: [ role ])
    worker = worker_class.new(results)
    [ described_class.read!(postings, purpose: "describe: #{role.role_title}", worker: worker), worker ]
  end

  # For roles not on record yet (2f step 3): the client suggests only those whose own page still has them.
  it "peeks at pages keeping nothing, then keeps a read for the role made from it, under the verifier's credential" do
    pages = [ { id: "c1:0", url: "https://acme.example/jobs/9", label: "Acme / Customer Engineer" },
              { id: "c1:1", url: "https://acme.example/jobs/10", label: "Acme / Recruiter" } ]
    worker = worker_class.new([ described("Discovery with enterprise buyers.").merge("target_id" => "c1:0"), { "target_id" => "c1:9" } ])

    peeked = nil
    expect { peeked = described_class.peek(pages, worker: worker) }.not_to change { [ RoleDescription.count, AgentCredential.count, AuditEvent.count ] }
    expect(worker.asked).to eq(command: "describe", targets: pages)
    expect(peeked.results["c1:0"]).to include("outcome" => "ok", "text" => "Discovery with enterprise buyers.")
    expect(peeked.results["c1:1"]).to eq("outcome" => "error", "reason" => "no result written")

    reads = described_class.keep!([ [ role, peeked.results["c1:0"] ] ], run_id: peeked.run_id, purpose: "mcp: suggest_roles")
    expect(reads.sole).to have_attributes(posting: role, outcome: "ok", new_version: true)
    expect(role.role_descriptions.sole).to have_attributes(text: "Discovery with enterprise buyers.", run_id: peeked.run_id)
    expect(AgentCredential.sole).to have_attributes(actor: "agent:verifier", scopes: %w[evidence:write], status: "revoked")
    expect(described_class.peek([], worker: worker).results).to eq({})
  end

  it "keeps a role's description as a version, read under the verifier's credential with evidence:write alone" do
    reads, worker = read(described("You will run technical discovery."))

    expect(worker.asked).to eq(command: "describe", targets: [ { id: role.id, url: role.job_url, label: "Acme / Sales Engineer" } ])
    expect(reads.sole).to have_attributes(outcome: "ok", new_version: true, summary: "Read: 5 words through Greenhouse's job API.")
    expect(role.role_descriptions.sole).to have_attributes(text: "You will run technical discovery.", read_via: "ats_api:greenhouse",
                                                          run_id: "20261016T120000Z-describe", first_read_at: Time.utc(2026, 10, 16, 12))
    expect(AgentCredential.sole.reload).to have_attributes(actor: "agent:verifier", scopes: %w[evidence:write], status: "revoked",
                                                           purpose: "describe: Sales Engineer")
  end

  it "says when it was read again with the same text, and keeps a changed text as a new version" do
    read(described("You will run technical discovery."))

    again, = read(described("You will run technical discovery.", at: "2026-10-18T09:00:00+00:00"))
    expect(again.sole).to have_attributes(new_version: false, summary: "Read again: the same text as on 2026-10-16.")
    expect(role.role_descriptions.sole.last_read_at).to eq(Time.utc(2026, 10, 18, 9))

    changed, = read(described("You will run discovery, and demos too.", at: "2026-10-20T09:00:00+00:00"))
    expect(changed.sole).to have_attributes(new_version: true, summary: /\AChanged since it was read on 2026-10-16: 7 words/)
    expect(role.role_descriptions.newest_first.pluck(:text)).to eq([ "You will run discovery, and demos too.",
                                                                    "You will run technical discovery." ])
  end

  it "says why it could not be read, and asks the worker nothing for a role with no page of its own" do
    linkless = create(:posting, company: company, role_title: "GTM Engineer", job_url: nil)

    reads, worker = read({ "kind" => "description", "target_id" => role.id, "outcome" => "gone", "reason" => "http_404" },
                         postings: [ role, linkless ])

    expect(reads.map { |r| [ r.posting, r.outcome, r.summary ] }).to contain_exactly(
      [ role, "gone", "Its board or its page no longer has it (http_404)." ],
      [ linkless, "no_page", "No page of its own on record: add its link to read its description." ]
    )
    expect(worker.asked[:targets].pluck(:id)).to eq([ role.id ])
    expect(RoleDescription.count).to eq(0)
  end

  # 4e: a careers page showing the role's posting from its ATS holds the company's text, not the role's.
  it "reads nothing from a careers page showing a posting from its ATS, and says to check the role first" do
    shown = create(:posting, company: company, role_title: "Recruiter", job_url: "https://acme.example/careers?gh_jid=4012399")

    reads, worker = read(described("You will run technical discovery."), postings: [ role, shown ])

    expect(worker.asked[:targets].pluck(:id)).to eq([ role.id ])
    expect(reads.find { |each| each.posting == shown }).to have_attributes(outcome: "no_page", summary: start_with("Its own page is its company's careers page"))
    expect(shown.role_descriptions).to be_empty
  end

  it "sets aside a result that breaks the contract, and goes on" do
    other = create(:posting, company: company, role_title: "Solutions Engineer", job_url: "https://acme.example/jobs/2")

    reads, = read(described("x", "content_hash" => "md5:nope"), described("Fine.", posting: other), postings: [ role, other ])

    expect(reads.map { |r| [ r.posting, r.outcome ] }).to contain_exactly([ role, "error" ], [ other, "ok" ])
    expect(reads.find { |r| r.posting == role }.summary).to include("content_hash must be a sha256")
  end

  it "goes with a suggestion the suggester withdraws" do
    suggested = create(:posting, company: company, role_title: "Solutions Engineer", tracking: "suggested", job_url: "https://acme.example/jobs/3")
    read(described("Text.", posting: suggested), postings: [ suggested ])

    as_agent("agent:suggester") { suggested.destroy! }

    expect(RoleDescription.count).to eq(0)
  end

  # 4e: a role added from its company's careers page, whose own posting a check found on its ATS since. What the
  # careers page said is the page's own text, not the role's: read again from its own page, kept as a version naming it.
  describe "a role whose own page moved" do
    let(:careers) { "https://acme.example/careers/" }

    def read_on(url, text, at: "2026-10-16T12:00:00+00:00")
      role.role_descriptions.create!(text: text, content_hash: "sha256:#{Digest::SHA256.hexdigest(text)}", read_via: "render", url: url,
                                     run_id: "r0", first_read_at: Time.iso8601(at), last_read_at: Time.iso8601(at))
    end

    it "is found by its description's page, a link's tracking aside, and read again from its own page" do
      read_on(careers, "Join us. We are hiring across teams.")
      same = create(:posting, company: company, role_title: "Recruiter", job_url: "https://acme.example/jobs/7")
      same.role_descriptions.create!(text: "Hire people.", content_hash: "h7", read_via: "render", url: "https://acme.example/jobs/7?utm_source=board",
                                     run_id: "r0", first_read_at: 1.day.ago, last_read_at: 1.day.ago)
      unread = create(:posting, company: company, role_title: "Designer", job_url: "https://acme.example/jobs/8")

      expect(described_class.moved([ role, same, unread ])).to eq([ role ])
      expect(described_class.elsewhere?(role, role.role_descriptions.sole)).to be(true)
      expect(described_class.elsewhere?(same, same.role_descriptions.sole)).to be(false)

      worker = worker_class.new([ described("You will run technical discovery.", at: "2026-10-18T09:00:00+00:00") ])
      said = described_class.reread_moved!([ role, same, unread ], worker: worker)

      expect(worker.asked[:targets]).to eq([ { id: role.id, url: role.job_url, label: "Acme / Sales Engineer" } ])
      expect(said).to eq("One role's own page moved, so its description was read again from it (free): 1 another text.")
      expect(role.role_descriptions.newest_first.pluck(:url)).to eq([ role.job_url, careers ])
      expect(described_class.moved([ role ])).to be_empty
      expect(AgentCredential.sole).to have_attributes(scopes: %w[evidence:write], purpose: "own page moved: descriptions read again")
      expect(described_class.reread_moved!([ role, same, unread ], worker: worker_class.new([]))).to be_nil
    end

    it "keeps the same text, read from its own page, as a version naming that page; says what it couldn't read" do
      read_on(careers, "You will run technical discovery.")
      other = create(:posting, company: company, role_title: "Solutions Engineer", job_url: "https://job-boards.greenhouse.io/acme/jobs/4012399")
      other.role_descriptions.create!(text: "Old.", content_hash: "h-old", read_via: "render", url: careers, run_id: "r0",
                                      first_read_at: 2.days.ago, last_read_at: 2.days.ago)
      worker = worker_class.new([ described("You will run technical discovery.", at: "2026-10-18T09:00:00+00:00"),
                                  { "kind" => "description", "target_id" => other.id, "outcome" => "gone", "reason" => "http_404" } ])

      said = described_class.reread_moved!([ role, other ], worker: worker)

      expect(said).to eq("2 roles' own pages moved, so their descriptions were read again from them (free): 1 the same text, " \
                         "1 not read (see the role's page).")
      newest = role.role_descriptions.newest_first.first
      expect(newest).to have_attributes(url: role.job_url, text: "You will run technical discovery.", first_read_at: Time.utc(2026, 10, 18, 9))
      expect(role.role_descriptions.count).to eq(2)
      expect(described_class.moved([ role, other ])).to eq([ other ]) # not read: the next check tries again

      again, = read(described("You will run technical discovery.", at: "2026-10-20T09:00:00+00:00"))
      expect(again.sole.summary).to eq("Read again: the same text as on 2026-10-18.")
    end

    it "says what a read from its moved page found, against what the page before said" do
      read_on(careers, "You will run technical discovery.")
      reads, = read(described("You will run technical discovery."))
      expect(reads.sole.summary).to start_with("Read from its own page, which moved: the same text as read from the page before on 2026-10-16: 5 words")

      read_on(careers, "Join us.", at: "2026-10-19T12:00:00+00:00")
      reads, = read(described("Discovery, and demos too.", at: "2026-10-20T09:00:00+00:00"))
      expect(reads.sole.summary).to start_with("Read from its own page, which moved: not what the page before said on 2026-10-19: 4 words")
    end
  end
end
