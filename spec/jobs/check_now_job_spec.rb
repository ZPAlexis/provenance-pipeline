require "rails_helper"

RSpec.describe CheckNowJob do
  let(:company) { create(:company, :resolved) }
  let(:run) { create(:check_run, :role, company: company) }
  let(:outcome) do
    Verifier::CheckNow::Outcome.new(answer: "not_found", summary: "None of the 12 roles on the page is it.",
                                     tally: { written: 1 }, cost_usd: 0.004, run_id: "20261007T120000Z-check")
  end

  before { allow(DatabaseBackup).to receive(:daily) }

  it "runs the check, backed up at most daily, and keeps what it found on the run" do
    allow(Verifier::CheckNow).to receive(:role).with(run.posting).and_return(outcome)

    described_class.perform_now(run)

    expect(DatabaseBackup).to have_received(:daily)
    expect(run.reload).to have_attributes(status: "done", answer: "not_found", summary: /12 roles/,
                                          tally: { "written" => 1 }, cost_usd: 0.004, run_id: "20261007T120000Z-check")
    expect([ run.started_at, run.finished_at ]).to all(be_present)
  end

  it "checks a company's whole careers page for a company run" do
    company_run = create(:check_run, company: company)
    allow(Verifier::CheckNow).to receive(:company).with(company).and_return(outcome)

    described_class.perform_now(company_run)

    expect(company_run.reload.status).to eq("done")
  end

  it "fails with why when the check stopped or broke, so the page never waits forever" do
    stopped = outcome.dup.tap { |o| o.stopped = "API credit exhausted"; o.summary = "Stopped before a result: API credit exhausted." }
    allow(Verifier::CheckNow).to receive(:role).and_return(stopped)
    described_class.perform_now(run)
    expect(run.reload).to have_attributes(status: "failed", error: /API credit exhausted/)

    broken = create(:check_run, :role, company: company)
    allow(Verifier::CheckNow).to receive(:role).and_raise(Verifier::Worker::Error, "the verification worker exited with status 1")
    described_class.perform_now(broken)
    expect(broken.reload).to have_attributes(status: "failed", error: "Error: the verification worker exited with status 1")
  end

  it "leaves a run that is no longer queued alone" do
    run.update!(status: "done")
    allow(Verifier::CheckNow).to receive(:role)

    described_class.perform_now(run)

    expect(Verifier::CheckNow).not_to have_received(:role)
  end
end
