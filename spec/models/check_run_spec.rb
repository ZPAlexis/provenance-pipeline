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

  it "names what it checks" do
    company = create(:company, name: "Acme")
    role = create(:posting, company: company, role_title: "RevOps Engineer")

    expect(build(:check_run, company: company).target_name).to eq("Acme")
    expect(build(:check_run, kind: "role", company: company, posting: role).target_name).to eq("RevOps Engineer at Acme")
  end
end
