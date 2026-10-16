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
end
