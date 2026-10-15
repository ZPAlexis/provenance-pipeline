require "rails_helper"

RSpec.describe "Pipeline", type: :request do
  let!(:company) { create(:company, :resolved, name: "Acme", domain: "acme.example") }
  let!(:role) { create(:posting, company: company, role_title: "Sales Engineer", tracking: "tracked") }

  it "starts an application from the role's page, at the stage and date given" do
    get role_path(role)
    expect(response.body).to include("Start an application")

    post applications_path, params: { posting_id: role.id, stage: "applied", on: "2026-10-10", note: "Through its own site." }

    application = role.reload.application
    expect(response).to redirect_to(application_path(application))
    expect(application).to have_attributes(stage: "applied", stage_changed_on: Date.new(2026, 10, 10))
    get role_path(role)
    expect(response.body).to include("Open its application")
  end

  it "says why an application was not started" do
    post applications_path, params: { posting_id: role.id, stage: "applied", on: (Date.current + 3).iso8601 }

    expect(flash[:alert]).to match(/Not started: a stage is reached on a day that has come/)
    expect(role.reload.application).to be_nil
  end

  describe "an application" do
    let!(:application) { create(:application, posting: role, stage: "applied", stage_changed_on: Date.new(2026, 10, 1)) }

    it "shows on the board at its stage, and on the dashboard" do
      get applications_path
      expect(response.body).to include("Sales Engineer", "Acme", "Applied <span class=\"muted\">(1)</span>")

      get root_path
      expect(response.body).to include("Pipeline", "Applied")
    end

    it "moves on the date it happened, logs what happened, and keeps notes, each on its timeline" do
      patch move_application_path(application), params: { stage: "screening", on: "2026-10-12", note: "Recruiter call booked." }
      expect(flash[:notice]).to eq("Moved to Screening.")

      post log_application_path(application), params: { kind: "call", on: "2026-10-14", summary: "Recruiter screen." }
      expect(flash[:notice]).to eq("Logged: call on 2026-10-14.")

      patch note_application_path(application), params: { notes: "Remote-first team.", comp_expectation: "25k a month" }

      get application_path(application)
      expect(response.body).to include("Recruiter call booked.", "Recruiter screen.", "Applied → ", "Remote-first team.",
                                       "25k a month")
      expect(application.reload).to have_attributes(stage: "screening", stage_changed_on: Date.new(2026, 10, 12))
    end

    it "says why a move was refused" do
      patch move_application_path(application), params: { stage: "hired" }

      expect(flash[:alert]).to start_with("Unknown stage \"hired\"")
      expect(application.reload.stage).to eq("applied")
    end
  end
end
