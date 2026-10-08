require "rails_helper"

RSpec.describe Verifier::Suggestions do
  let(:company) { create(:company, :resolved, name: "Acme") }
  let(:profile) { SearchProfile.create!(titles: [ "Solutions Engineer" ], places: [ "Brazil" ]) }
  let(:run_dir) { Rails.root.join("tmp/verifier/spec-suggest") }
  let!(:read) do
    create(:page_check, company: company, purpose: "verification", step: nil, url: company.careers_page_url,
                        run_id: "20261008T100000Z-verify", checked_at: 1.day.ago,
                        listings: [ listing("Solutions Engineer", 1), listing("Recruiter", 2) ])
  end

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

  def listing(title, number, location = "Remote - Brazil")
    { "title" => title, "location" => location, "url" => "https://acme.example/jobs/#{number}", "work_mode" => "remote" }
  end

  def fit(title, index: 0, number: index + 1, suggested: true, ruled_out: nil, on_record: nil, notes: [])
    { "listing_index" => index, "listing" => listing(title, number), "title" => "Solutions Engineer", "level" => nil,
      "place" => "Brazil", "work_mode" => "remote", "suggested" => suggested, "ruled_out" => ruled_out, "notes" => notes,
      "reasoning" => "Its title holds every word of \"Solutions Engineer\"; it is in Brazil.", "on_record" => on_record }
  end

  def result(target, roles, listed: {}, **overrides)
    { "kind" => "suggestion", "target_id" => target.id, "page_check_id" => read.id, "outcome" => "ok", "weighed" => 2,
      "roles" => roles, "listed" => listed }.merge(overrides)
  end

  after { FileUtils.rm_rf(run_dir) }

  describe ".preview" do
    it "weighs every watched company's latest list in the worker, sets apart roles on record, and writes nothing" do
      tracked = create(:posting, company: company, role_title: "Senior Solutions Engineer")
      worker = worker_class.new(run_dir, [ result(company, [ fit("Solutions Engineer"), fit("Senior Solutions Engineer", index: 1, on_record: tracked.id),
                                                             fit("Sr. Solutions Engineer", suggested: false, ruled_out: "place") ]) ])
      create(:company, :resolved, name: "Unread")

      preview = nil
      expect { preview = described_class.preview(profile, worker: worker) }
        .not_to change { [ AuditEvent.count, Posting.count, PageCheck.count ] }

      expect(worker.asked[:command]).to eq("suggest")
      expect(worker.asked[:targets]).to contain_exactly(include(id: company.id, profile: profile.to_worker))
      expect(worker.asked[:targets].first[:postings]).to eq([ { id: tracked.id, title: "Senior Solutions Engineer", location: nil, url: nil } ])
      expect(preview).to have_attributes(companies: 1, unread: 1, weighed: 2, problems: [])
      expect(preview.new_roles.map { |f| f.listing["title"] }).to eq([ "Solutions Engineer" ])
      expect(preview.on_record.map(&:on_record)).to eq([ tracked ])
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

  describe ".refresh!" do
    before { allow(DatabaseBackup).to receive(:daily) }

    def refresh(*results) = described_class.refresh!(profile: profile, worker: worker_class.new(run_dir, results))

    it "suggests each fitting role not on record, as the suggester, with why and as its page listed it" do
      outcome = refresh(result(company, [ fit("Solutions Engineer") ]))

      suggestion = company.postings.sole
      expect(suggestion).to have_attributes(
        role_title: "Solutions Engineer", location: "Remote - Brazil", job_url: "https://acme.example/jobs/1",
        tracking: "suggested", verification_state: "verified_live", roles_listed_count: 2, work_mode: "remote"
      )
      expect(suggestion.last_checked_at).to be_within(1.second).of(read.checked_at)
      expect(suggestion.fit).to include("profile_id" => profile.id, "title" => "Solutions Engineer", "place" => "Brazil",
                                        "reasoning" => a_string_including("it is in Brazil"))
      event = AuditEvent.find_by!(target: suggestion)
      expect(event).to have_attributes(actor: "agent:suggester", action: "create")
      expect(event.reasoning).to include("Suggested: Its title holds", "check #{read.id}", "Run #{outcome.run_id}.")
      expect(outcome).to have_attributes(created: 1, updated: 0, withdrawn: 0, problems: [])
      expect(outcome.summary).to eq("Suggestions: 1 new.")
      expect(DatabaseBackup).to have_received(:daily)
    end

    it "never touches a role the operator tracks or dismissed, and suggests no role twice" do
      tracked = create(:posting, company: company, role_title: "Solutions Engineer", job_url: "https://acme.example/jobs/1")
      dismissed = create(:posting, company: company, role_title: "Recruiter", tracking: "dismissed")
      roles = [ fit("Solutions Engineer", on_record: tracked.id), fit("Recruiter", index: 1, on_record: dismissed.id) ]

      expect { refresh(result(company, roles, listed: { tracked.id => 0, dismissed.id => 1 })) }.not_to change(AuditEvent, :count)
      expect([ tracked.reload.fit, dismissed.reload.tracking ]).to eq([ nil, "dismissed" ])

      # Its link already on record, though the worker did not say so: a guard, never a second one.
      expect { refresh(result(company, [ fit("Solutions Engineer") ])) }.not_to change(Posting, :count)
    end

    it "brings a standing suggestion's reasons up to date, audited only when they changed" do
      refresh(result(company, [ fit("Solutions Engineer") ]))
      suggestion = company.postings.sole
      standing = fit("Solutions Engineer", on_record: suggestion.id, notes: [ "level_not_stated" ])

      expect { refresh(result(company, [ standing ], listed: { suggestion.id => 0 })) }.to change(AuditEvent, :count).by(1)
      expect(suggestion.reload.fit["notes"]).to eq([ "level_not_stated" ])
      expect(AuditEvent.find_by!(target: suggestion, action: "update").reasoning).to start_with("Still fits: ")

      outcome = nil
      expect { outcome = refresh(result(company, [ standing ], listed: { suggestion.id => 0 })) }.not_to change(AuditEvent, :count)
      expect(outcome).to have_attributes(created: 0, updated: 0, withdrawn: 0)
    end

    it "withdraws an untouched suggestion that no longer fits, or is gone from the whole list, keeping its record" do
      refresh(result(company, [ fit("Solutions Engineer"), fit("Recruiter", index: 1) ]))
      ruled, untitled = company.postings.order(:role_title).to_a.reverse
      gone = create(:posting, :credible_negative, company: company, role_title: "Old Role", tracking: "suggested")
      unseen = create(:posting, company: company, role_title: "Page Two Role", tracking: "suggested")
      roles = [ fit("Solutions Engineer", suggested: false, ruled_out: "place", on_record: ruled.id) ]

      outcome = refresh(result(company, roles, listed: { ruled.id => 0, untitled.id => 1 }))

      expect(outcome.withdrawn).to eq(3)
      expect(company.postings.reload).to contain_exactly(unseen) # not in this read, which may be part of the list
      reasons = AuditEvent.where(action: "destroy", actor: "agent:suggester").to_a.to_h { |e| [ e.target_id, e.reasoning ] }
      expect(reasons[ruled.id]).to start_with("Withdrawn: it no longer fits the profile. Its title holds")
      expect(reasons[untitled.id]).to start_with("Withdrawn: its title no longer holds any of the profile's titles.")
      expect(reasons[gone.id]).to start_with("Withdrawn: it is no longer listed")
      expect(AuditEvent.find_by!(target_id: ruled.id, action: "destroy").changes_made)
        .to include("role_title" => [ "Solutions Engineer", nil ], "tracking" => [ "suggested", nil ])
    end

    it "writes nothing without a saved profile, and runs nothing" do
      worker = worker_class.new(run_dir, [])

      outcome = described_class.refresh!(profile: nil, worker: worker)

      expect(outcome.problems).to eq([ "No search profile is saved yet." ])
      expect(worker.asked).to be_nil
    end
  end
end
