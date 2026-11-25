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

  # 4e: read from its company's careers page when it was added; a check found its own posting on the ATS since.
  it "says a description read from a page no longer the role's own, on the role's page and its application's" do
    role.role_descriptions.create!(text: "Join us.", content_hash: "h1", read_via: "render", url: "https://www.acme.example/careers/",
                                   run_id: "r1", first_read_at: 1.day.ago, last_read_at: 1.day.ago)
    create(:application, posting: role, company: company, stage: "applied")

    get role_path(role)
    expect(response.body).to include("which is no longer its own page", "acme.example ↗", "greenhouse.io ↗", "each check reads it again too")

    get application_path(role.application)
    expect(response.body).to include("Read from a page that is no longer the role's own")

    role.role_descriptions.create!(text: "Join us.", content_hash: "h1", read_via: "ats_api:greenhouse", url: role.job_url, run_id: "r2",
                                   first_read_at: 1.hour.ago, last_read_at: 1.hour.ago)
    get role_path(role)
    expect(response.body).not_to include("which is no longer its own page")
    expect(response.body).to include("2 versions, new on", "(the same text, from its own page when it moved)")

    get changes_path # the last 7 days: the same text from its new page is a version, not a change
    expect(response.body).not_to include("id=\"descriptions-changed\"")
  end

  it "is read again, in the background, when the operator moves the role's own page" do
    version("You will run discovery.", at: 1.day.ago)

    expect { patch own_page_role_path(role), params: { link: "https://job-boards.greenhouse.io/acme/jobs/4012399" } }
      .to have_enqueued_job(CheckNowJob)

    expect(flash[:notice]).to eq("Its own page is now https://job-boards.greenhouse.io/acme/jobs/4012399. Its description was read " \
                                 "from the page before: reading it again from this one, free.")
    expect(CheckRun.sole).to have_attributes(kind: "describe", posting: role)
  end
end
