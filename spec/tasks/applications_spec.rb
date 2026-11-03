require "rails_helper"

# The pipeline's commands (2a), as the operator runs them: each write audited as theirs, backed up first, and a
# command given something wrong refused before any backup.
RSpec.describe "applications: commands" do
  let!(:company) { create(:company, :resolved, name: "Acme", domain: "acme.example") }
  let!(:role) { create(:posting, :verified_live, company: company, role_title: "Sales Engineer", tracking: "tracked") }

  it "starts an application, moves it, logs what happened, and shows it, each audited as the operator" do
    started = run_task("applications:start", role.id, STAGE: "applied", ON: 2.days.ago.to_date.iso8601, NOTE: "Applied on their site.")
    application = role.reload.application
    expect(started.out).to include("Acme / Sales Engineer: started at Applied on #{2.days.ago.to_date} (#{application.id})")

    expect(run_task("applications:move", application.id, STAGE: "screening", NOTE: "A call booked.").out)
      .to include("Acme / Sales Engineer: Screening since #{Date.current}")
    expect(run_task("applications:log", application.id, KIND: "call", SUMMARY: "Talked to the recruiter.").out)
      .to include("Acme / Sales Engineer: call on #{Date.current} logged")
    expect(DatabaseBackup).to have_received(:call).exactly(3).times
    expect(AuditEvent.where(target: application).pluck(:actor).uniq).to eq([ AuditEvent::OPERATOR ])

    expect(run_task("applications:list").out).to include("Screening (1)", "#{application.id}  Acme / Sales Engineer")
    expect(run_task("applications:show", application.id).out)
      .to include("Screening since #{Date.current}", "Contacts: none linked", "Timeline", "Talked to the recruiter.")
  end

  it "refuses before any backup: a stage not yet reached, a stage it doesn't know, a role already applied to" do
    expect(run_task("applications:start", role.id, ON: 1.day.from_now.to_date.iso8601).aborted)
      .to eq("A stage is reached on a day that has come: #{1.day.from_now.to_date} is still ahead.")
    expect(run_task("applications:start", role.id, STAGE: "hired").aborted).to start_with("STAGE is one of: interested, applied")
    expect(run_task("applications:show", "nope").aborted).to eq('No application "nope": see applications:list.')

    create(:application, posting: role)
    expect(run_task("applications:start", role.id).aborted).to start_with("Sales Engineer already has an application")
    expect(DatabaseBackup).not_to have_received(:call)
  end
end
