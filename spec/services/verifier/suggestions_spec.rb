require "rails_helper"

RSpec.describe Verifier::Suggestions do
  let(:company) { create(:company, :resolved, name: "Acme") }
  let(:profile) { SearchProfile.new(titles: [ "Solutions Engineer" ], places: [ "Brazil" ]) }
  let(:run_dir) { Rails.root.join("tmp/verifier/spec-suggest") }

  # Stands in for Verifier::Worker: records what it was asked to run, and hands back the results given.
  let(:worker_class) do
    Class.new do
      attr_reader :asked

      def initialize(dir, results, stopped: nil)
        @dir, @results, @stopped = dir, results, stopped
      end

      def run(targets, command:)
        @asked = { targets: targets, command: command }
        FileUtils.mkdir_p(@dir)
        Verifier::Worker::Run.new(dir: @dir, results: @results, stopped: @stopped)
      end
    end
  end

  def listing(title, location = "Remote - Brazil") = { "title" => title, "location" => location, "work_mode" => "remote" }

  def fit(title, suggested: true, ruled_out: nil, notes: [])
    { "listing_index" => 0, "listing" => listing(title), "title" => "Solutions Engineer", "level" => nil, "place" => "Brazil",
      "work_mode" => "remote", "suggested" => suggested, "ruled_out" => ruled_out, "notes" => notes, "reasoning" => "Its title holds it." }
  end

  def result(target, roles, **overrides)
    { "kind" => "suggestion", "target_id" => target.id, "page_check_id" => "pc", "outcome" => "ok", "weighed" => 2,
      "roles" => roles }.merge(overrides)
  end

  before do
    create(:page_check, company: company, purpose: "verification", step: nil, url: company.careers_page_url,
                        checked_at: 1.day.ago, listings: [ listing("Solutions Engineer"), listing("Recruiter") ])
  end

  it "weighs every watched company's latest list in the worker, and writes nothing" do
    worker = worker_class.new(run_dir, [ result(company, [ fit("Solutions Engineer"), fit("Sr. Solutions Engineer", suggested: false, ruled_out: "place") ]) ])
    create(:company, :resolved, name: "Unread")

    preview = nil
    expect { preview = described_class.preview(profile, worker: worker) }
      .not_to change { [ AuditEvent.count, Posting.count, PageCheck.count, SearchProfile.count ] }

    expect(worker.asked[:command]).to eq("suggest")
    expect(worker.asked[:targets]).to contain_exactly(include(id: company.id, profile: profile.to_worker))
    expect(preview).to have_attributes(companies: 1, unread: 1, weighed: 2, problems: [])
    expect(preview.suggested.map { |f| [ f.company, f.listing["title"] ] }).to eq([ [ company, "Solutions Engineer" ] ])
    expect(preview.ruled_out.map(&:ruled_out)).to eq([ "place" ])
    expect(run_dir).not_to exist # a preview keeps nothing
  end

  it "shows nothing from a result that breaks the contract, or failed, and says which" do
    other = create(:company, :resolved, name: "Beta")
    create(:page_check, company: other, purpose: "verification", step: nil, url: other.careers_page_url, checked_at: 1.day.ago)
    worker = worker_class.new(run_dir, [ result(company, [ fit("Solutions Engineer", ruled_out: "place") ]),
                                         result(other, [], "outcome" => "error", "reason" => "unexpected:KeyError") ],
                              stopped: "API credit exhausted")

    preview = described_class.preview(profile, worker: worker)

    expect(preview.fits).to be_empty
    expect(preview.problems).to eq([ "Acme: role 1: a suggested role cannot be ruled out", "Beta: unexpected:KeyError",
                                     "The worker stopped early: API credit exhausted." ])
  end

  it "runs nothing when no watched page has been read" do
    PageCheck.delete_all
    worker = worker_class.new(run_dir, [])

    expect(described_class.preview(profile, worker: worker)).to have_attributes(companies: 0, unread: 1, fits: [])
    expect(worker.asked).to be_nil
  end
end
