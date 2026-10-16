require "rails_helper"

RSpec.describe "Descriptions", type: :request do
  include ActiveJob::TestHelper

  let!(:company) { create(:company, :resolved, name: "Acme", domain: "acme.example") }
  let!(:role) do
    create(:posting, company: company, role_title: "Sales Engineer", tracking: "tracked",
                     job_url: "https://job-boards.greenhouse.io/acme/jobs/4012345")
  end

  def version(text, at:)
    role.role_descriptions.create!(text: text, content_hash: "sha256:#{Digest::SHA256.hexdigest(text)}", read_via: "ats_api:greenhouse",
                                   url: role.job_url, run_id: "r-#{at.to_i}", first_read_at: at, last_read_at: at)
  end

  it "reads a role's description in the background from its page, free" do
    get role_path(role)
    expect(response.body).to include("Read its description", "never the LLM")

    expect { post check_runs_path, params: { posting_id: role.id, describe: 1 } }.to have_enqueued_job(CheckNowJob)
    expect(CheckRun.sole).to have_attributes(kind: "describe", posting: role, ceiling_usd: 0)

    get role_path(role)
    expect(response.body).to include("Waiting for the check before it to finish")
  end

  it "says when a role has no page of its own to read" do
    linkless = create(:posting, company: company, role_title: "GTM Engineer", job_url: nil)

    post check_runs_path, params: { posting_id: linkless.id, describe: 1 }

    expect(flash[:alert]).to start_with("No page of its own on record")
    expect(CheckRun.count).to eq(0)
  end

  it "shows the description, its versions, and changed ones in what changed" do
    version("You will run discovery.", at: 3.days.ago)
    version("You will run discovery and demos.", at: 1.hour.ago)
    create(:check_run, kind: "all", company: nil, status: "done", started_at: 2.days.ago, finished_at: 2.days.ago + 1.hour, total: 1)

    get role_path(role)
    expect(response.body).to include("You will run discovery and demos.", "2 versions", "Earlier versions", "Read it again")

    get changes_path
    expect(response.body).to include("Descriptions changed", "Sales Engineer")
  end

  it "is read when an application starts" do
    expect { post applications_path, params: { posting_id: role.id, stage: "applied" } }.to have_enqueued_job(CheckNowJob)

    expect(CheckRun.sole).to have_attributes(kind: "describe", posting: role)
  end

  it "never holds up a check of the role, nor a check the read" do
    CheckRun.start_describe!(role)

    check = CheckRun.start_for!(role)

    expect([ check.kind, CheckRun.active.count ]).to eq([ "role", 2 ])
  end
end
