require "rails_helper"

RSpec.describe CheckRun do
  it "needs a known kind and status, and a role to check a role" do
    expect(build(:check_run)).to be_valid
    expect(build(:check_run, kind: "everything")).not_to be_valid
    expect(build(:check_run, status: "paused")).not_to be_valid
    expect(build(:check_run, kind: "role")).not_to be_valid
    expect(build(:check_run, :role)).to be_valid
  end

  # The in-process queue does not survive the server stopping.
  it "marks a run still active an hour on as cut off, leaving recent and finished ones alone" do
    stale = create(:check_run, status: "running", updated_at: 2.hours.ago)
    fresh = create(:check_run, status: "running")
    done = create(:check_run, status: "done", updated_at: 2.hours.ago)

    described_class.abandon_stale!

    expect(stale.reload).to have_attributes(status: "failed", error: /server stopped/)
    expect(stale.finished_at).to be_present
    expect(fresh.reload.status).to eq("running")
    expect(done.reload.status).to eq("done")
  end

  # Found 2026-10-07: a restart mid-check left the run active, blocking that role's next check for an hour.
  it "marks a run left active by an earlier server process as cut off at once, on the in-process queue" do
    allow(described_class).to receive(:in_process_queue?).and_return(true)
    lost = create(:check_run, status: "running", updated_at: 5.minutes.ago)
    current = create(:check_run, status: "running", updated_at: 1.minute.ago)

    described_class.abandon_stale!(booted_at: 2.minutes.ago)

    expect(lost.reload.status).to eq("failed")
    expect(current.reload.status).to eq("running")
  end

  describe "a check of everything" do
    it "needs no company, and is one at a time" do
      allow(Verifier::CheckAll).to receive(:plan).and_return(Verifier::CheckAll::Plan.new(targets: [], via_board: 0, reusable: 0, ceiling: 0.42))

      first = described_class.start_all!

      expect(first).to have_attributes(kind: "all", company: nil, ceiling_usd: 0.42, status: "queued")
      expect(described_class.start_all!).to eq(first)
      expect(first.target_name).to eq("everything")
    end

    it "counts its progress from its results file as the worker writes it" do
      run = create(:check_run, kind: "all", company: nil, run_id: "20261014T120000Z-verify-spec", total: 3)
      dir = Rails.root.join("tmp/verifier", run.run_id)
      FileUtils.mkdir_p(dir)
      dir.join("results.jsonl").write("{}
{}
")

      expect(run.progress).to eq(2)
    ensure
      FileUtils.rm_rf(dir) if dir
    end

    it "is cut off only after a batch's time, not a single check's" do
      long = create(:check_run, kind: "all", company: nil, status: "running", updated_at: 2.hours.ago)
      lost = create(:check_run, kind: "all", company: nil, status: "running", updated_at: 5.hours.ago)

      described_class.abandon_stale!

      expect([ long.reload.status, lost.reload.status ]).to eq(%w[running failed])
    end
  end

  it "names what it checks" do
    company = create(:company, name: "Acme")
    role = create(:posting, company: company, role_title: "RevOps Engineer")

    expect(build(:check_run, company: company).target_name).to eq("Acme")
    expect(build(:check_run, kind: "role", company: company, posting: role).target_name).to eq("RevOps Engineer at Acme")
  end
end
