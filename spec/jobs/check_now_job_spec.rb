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

  it "checks everything for a run over everything, backed up in full by the check itself" do
    everything = create(:check_run, kind: "all", company: nil)
    allow(Verifier::CheckAll).to receive(:run!).with(everything)
      .and_return(Verifier::CheckAll::Outcome.new(summary: "137 companies read.", tally: { written: 3 }, cost_usd: 0.4,
                                                   run_id: "20261014T120000Z-verify"))

    described_class.perform_now(everything)

    expect(everything.reload).to have_attributes(status: "done", summary: "137 companies read.", cost_usd: 0.4)
    expect(DatabaseBackup).not_to have_received(:daily)
  end

  it "reads a role's description for a description run, free, and says what it found" do
    described = create(:check_run, kind: "describe", company: company, posting: create(:posting, company: company))
    read = Verifier::Descriptions::Read.new(posting: described.posting, outcome: "ok", summary: "Read: 480 words through Ashby's job API.",
                                            version: nil, new_version: true)
    allow(Verifier::Descriptions).to receive(:read!).and_return([ read ])

    described_class.perform_now(described)

    expect(described.reload).to have_attributes(status: "done", answer: "read", summary: /480 words/, cost_usd: 0)
  end

  it "writes a resume review for a review run, in the language asked, and keeps what it cost" do
    application = create(:application, posting: create(:posting, company: company))
    asked = create(:check_run, kind: "review", company: company, posting: application.posting, request: { "language" => "Portuguese" })
    written = ResumeReviews::Written.new(application: application, review: ResumeReview.new, summary: "Resume review in Portuguese: 3 strengths.",
                                         cost_usd: 0.056, run_id: "20261023T120000Z-review")
    allow(ResumeReviews).to receive(:write!).and_return(written)

    described_class.perform_now(asked)

    expect(ResumeReviews).to have_received(:write!).with(application, language: "Portuguese", issued_by: "human:operator")
    expect(asked.reload).to have_attributes(status: "done", answer: "reviewed", summary: /3 strengths/, cost_usd: 0.056)
  end

  it "writes a draft for a draft run, as it was asked, and keeps what it cost" do
    application = create(:application, posting: create(:posting, company: company))
    asked = create(:check_run, kind: "draft", company: company, posting: application.posting,
                               request: { "kind" => "outreach", "language" => "Portuguese", "guidance" => "Discovery." })
    written = Drafts::Written.new(application: application, draft: Draft.new, summary: "Outreach note in Portuguese: 96 words.",
                                  cost_usd: 0.061, run_id: "20261019T120000Z-draft")
    allow(Drafts).to receive(:write!).and_return(written)

    described_class.perform_now(asked)

    expect(Drafts).to have_received(:write!).with(application, kind: "outreach", language: "Portuguese", guidance: "Discovery.",
                                                               issued_by: "human:operator")
    expect(asked.reload).to have_attributes(status: "done", answer: "drafted", summary: /96 words/, cost_usd: 0.061,
                                            run_id: "20261019T120000Z-draft")
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
