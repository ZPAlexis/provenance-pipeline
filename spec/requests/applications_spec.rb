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

    # Found 2026-10-19: a move on the same day as the stage before records no date, and the page broke on it.
    it "shows a move made the same day as the stage before, dated as that stage was" do
      started = Pipeline.start!(create(:posting, company: company, role_title: "GTM Engineer", tracking: "tracked"),
                                stage: "interested", on: Date.new(2026, 10, 15))
      Pipeline.move!(started, "withdrawn", on: Date.new(2026, 10, 15), note: "Not for me.")

      get application_path(started)

      expect(response).to have_http_status(:success)
      expect(response.body).to include("2026-10-15", "Not for me.")
    end

    it "shows where it stands as a path, each stage a step to move it to" do
      Pipeline.move!(application, "interviewing", on: Date.new(2026, 10, 12))

      get application_path(application)

      path = response.body[%r{<nav class="stage-path".*?</nav>}m]
      expect(path.scan(/class="(\w+)"/).flatten).to eq(%w[done done done current ahead ahead])
      expect(path).to include("Interviewing", "Accepted", "stage=offer#move")

      get application_path(application, stage: "offer")
      expect(response.body).to include(%(<option selected="selected" value="offer">Offer</option>))
    end

    it "closes its path at the outcome, from the stage it closed at" do
      Pipeline.move!(application, "rejected", on: Date.new(2026, 10, 12))

      get application_path(application)

      path = response.body[%r{<nav class="stage-path".*?</nav>}m]
      expect(path.scan(/class="(\w+)"/).flatten).to eq(%w[done done ahead ahead ahead lost])
      expect(path).to include("Rejected")
    end

    it "edits and deletes an activity, each audited, the deleted one's record keeping what it said" do
      activity = Pipeline.log!(application, kind: "email", summary: "Wrote to the recruiter.", on: Date.new(2026, 10, 2))

      patch application_activity_path(application, activity), params: { kind: "call", summary: "Called the recruiter.", on: "2026-10-03" }
      expect(flash[:notice]).to eq("Activity saved.")
      expect(activity.reload).to have_attributes(kind: "call", summary: "Called the recruiter.", occurred_on: Date.new(2026, 10, 3))

      patch application_activity_path(application, activity), params: { kind: "call", summary: "Called the recruiter.", on: "2026-10-03" }
      expect(flash[:notice]).to start_with("Nothing to save")

      delete application_activity_path(application, activity)
      expect(flash[:notice]).to eq("Activity deleted.")
      expect(Activity.exists?(activity.id)).to be(false)
      expect(AuditEvent.find_by!(target_type: "Activity", target_id: activity.id, action: "destroy").changes_made)
        .to include("summary" => [ "Called the recruiter.", nil ])
    end

    it "says why a move was refused" do
      patch move_application_path(application), params: { stage: "hired" }

      expect(flash[:alert]).to start_with("Unknown stage \"hired\"")
      expect(application.reload.stage).to eq("applied")
    end
  end
end
