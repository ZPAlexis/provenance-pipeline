require "rails_helper"

# The operator's own links (4d step 3): their website, GitHub or another portfolio, kept with the profile by the
# operator alone (never LinkedIn), each audited by hashes; read by the app, free, as the verifier with evidence:write
# alone, each page kept as a version.
RSpec.describe ProfileLinks do
  let!(:profile) { SearchProfile.create!(titles: [ "Solutions Engineer" ]) }
  let(:run_dir) { Rails.root.join("tmp/verifier/20261117T120000Z-portfolio-spec") }

  after { FileUtils.rm_rf(run_dir) }

  # Stands in for Verifier::Worker: keeps what it was asked, and answers with `results`.
  let(:worker_class) do
    Class.new do
      attr_reader :asked, :run_dir

      def initialize(results, run_dir) = (@results, @run_dir = results, run_dir)

      def run(targets, command:)
        @asked = { targets: targets, command: command }
        FileUtils.mkdir_p(@run_dir)
        @run_dir.join("results.jsonl").write("{}")
        Verifier::Worker::Run.new(dir: @run_dir, results: @results.call(targets), stopped: nil)
      end
    end
  end

  def page(url, text, title: nil, via: "render")
    { "url" => url, "title" => title, "text" => text, "content_hash" => Resume.digest(text), "read_via" => via }
  end

  def ok(link, *pages, skipped: 0, at: "2026-11-17T12:00:00Z")
    { "kind" => "portfolio", "target_id" => link[:id], "url" => link[:url], "outcome" => "ok", "pages" => pages, "skipped" => skipped,
      "checked_at" => at }
  end

  def read(&answers)
    worker = worker_class.new(answers, run_dir)
    [ described_class.read!(profile.profile_links.to_a, worker: worker), worker ]
  end

  it "keeps the links as given, https where none is said, a label from the host, audited by hashes alone" do
    links = described_class.keep!(profile, [ { label: "", url: "jordan.example/en" }, { label: "GitHub", url: "https://github.com/jsample" },
                                             { label: "", url: "" } ])

    expect(links.map { |link| [ link.label, link.url, link.position ] })
      .to eq([ [ "jordan.example", "https://jordan.example/en", 0 ], [ "GitHub", "https://github.com/jsample", 1 ] ])
    event = AuditEvent.find_by!(target: links.first)
    expect(event).to have_attributes(actor: "human:operator", action: "create")
    expect(event.changes_made.keys).to contain_exactly("label_hash", "url_hash", "position")
    expect(event.changes_made.to_json).not_to include("jordan", "github")

    later = described_class.keep!(profile, [ { label: "GitHub", url: "https://github.com/jsample" } ])
    expect(later.map(&:url)).to eq([ "https://github.com/jsample" ])
    expect(AuditEvent.where(target_type: "ProfileLink", action: "destroy").count).to eq(1)
    expect(AuditEvent.where(target: later.sole, action: "update").sole.changes_made).to eq("position" => [ 1, 0 ])
  end

  it "refuses LinkedIn, a sixth link, and an address that isn't one, saving none of them" do
    described_class.keep!(profile, [ { url: "https://jordan.example" } ])

    expect { described_class.keep!(profile, [ { url: "https://www.linkedin.com/in/jsample" } ]) }
      .to raise_error(ArgumentError, /LinkedIn isn't read: its pages can't be fetched/)
    expect { described_class.keep!(profile, Array.new(6) { |n| { url: "https://site#{n}.example" } }) }
      .to raise_error(ArgumentError, "keep at most 5 links")
    expect { described_class.keep!(profile, [ { url: "ftp://jordan.example" } ]) }.to raise_error(ArgumentError, /must be a web address/)
    expect(profile.profile_links.pluck(:url)).to eq([ "https://jordan.example" ])
  end

  it "reads the links free as the verifier, keeping each page a version, and says what came of each" do
    described_class.keep!(profile, [ { label: "Website", url: "https://jordan.example/en" }, { label: "Blog", url: "https://blog.example" } ])

    result, worker = read do |targets|
      [ ok(targets.first, page("https://jordan.example/en", "Jordan Sample, solutions engineer.", title: "Home"),
           page("https://jordan.example/en/projects/alpha", "Project Alpha: an audit log."), skipped: 2),
        { "kind" => "portfolio", "target_id" => targets.last[:id], "url" => targets.last[:url], "outcome" => "blocked",
          "reason" => "robots_disallowed", "pages" => [] } ]
    end

    expect(worker.asked).to eq(command: "portfolio", targets: profile.profile_links.map { |link| { id: link.id, url: link.url, label: link.label } })
    expect(run_dir).not_to exist # its results hold the pages' text
    website, blog = profile.profile_links.to_a
    expect(website).to have_attributes(read_outcome: "ok", read_skipped: 2, read_at: Time.utc(2026, 11, 17, 12))
    expect(website.pages.map(&:title)).to eq([ "Home", nil ])
    expect(blog).to have_attributes(read_outcome: "blocked", read_reason: "robots_disallowed")
    expect(result).to have_attributes(finished?: true, answer: "read", cost_usd: 0.0, tally: { "ok" => 1, "blocked" => 1 },
                                      summary: "Website: 2 pages, 2 left unread; Blog: refused (robots.txt keeps us off it)")
    expect(AgentCredential.sole).to have_attributes(actor: "agent:verifier", scopes: %w[evidence:write], status: "revoked")
  end

  it "keeps the same text read again as it was, saying when it was seen, and a changed page as a new version" do
    described_class.keep!(profile, [ { label: "Website", url: "https://jordan.example" } ])
    read { |targets| [ ok(targets.first, page("https://jordan.example", "Version one.")) ] }
    read { |targets| [ ok(targets.first, page("https://jordan.example", "Version one."), at: "2026-11-18T12:00:00Z") ] }

    link = profile.profile_links.sole
    expect(link.link_pages.sole).to have_attributes(first_read_at: Time.utc(2026, 11, 17, 12), last_read_at: Time.utc(2026, 11, 18, 12))

    read { |targets| [ ok(targets.first, page("https://jordan.example", "Version two."), at: "2026-11-19T12:00:00Z") ] }
    expect(link.reload.link_pages.count).to eq(2)
    expect(link.pages.map(&:text)).to eq([ "Version two." ])

    read { |targets| [ ok(targets.first, { "url" => "nope" }) ] }
    expect(link.reload).to have_attributes(read_outcome: "error", read_reason: start_with("not recorded: page 1 must say its address"))
  end

  it "lets the verifier record what a read found, and no agent change a link or add one" do
    link = described_class.keep!(profile, [ { label: "Website", url: "https://jordan.example" } ]).sole

    expect { as_agent("agent:verifier") { link.update!(url: "https://other.example") } }.to raise_error(Authority::Denied, /may not update a profile link/)
    expect { as_agent("agent:assistant") { profile.profile_links.create!(label: "x", url: "https://x.example") } }
      .to raise_error(Authority::Denied, /may not create a profile link/)
    expect(Authority::HUMAN_ONLY.join).to include("the background information and its links")
  end
end
