require "rails_helper"

RSpec.describe "Review", type: :request do
  it "lists what is waiting, by kind, with the question, what was seen, the proposal, and what to check" do
    company = create(:company, name: "Acme", resolution_status: "failed", resolution_failure: "not_found")
    ReviewQueue.sync!(company)

    get review_path

    expect(response).to have_http_status(:success)
    expect(response.body).to include("To review", "Where does Acme list its open roles?", "No careers page found (not_found).",
                                     "Find its careers page again", "Raised by Verifier", "What to check", "Review (1)")

    get review_path(kind: "suspect_verdict")
    expect(response.body).to include("Nothing to review of this kind.")
  end

  it "names the company and the role an item is about at its top, each linked to its page" do
    company = create(:company, :resolved, name: "Acme", domain: "acme.example")
    role = create(:posting, company: company, role_title: "Sales Engineer", verification_state: "inaccessible", last_checked_at: 1.day.ago)
    ReviewQueue.sync!(company)

    get review_path

    head = response.body[/<div class="review-head">.*?<\/div>/m]
    expect(head).to include(%(href="#{company_path(company)}"), ">Acme</a>", %(href="#{role_path(role)}"), ">Sales Engineer</a>")
  end

  it "shows how many are waiting on the dashboard" do
    company = create(:company, resolution_status: "failed", resolution_failure: "blocked")
    ReviewQueue.sync!(company)

    get root_path

    expect(response.body).to include("To review")
  end
end

RSpec.describe "Deciding a review item", type: :request do
  include ActiveJob::TestHelper

  def item_for(company)
    ReviewQueue.sync!(company)
    company.review_items.open.sole
  end

  it "confirms a careers page, closing the item with the operator's decision, audited as theirs" do
    company = create(:company, :resolution_candidate, name: "Acme", domain: "acme.example")
    item = item_for(company)

    get review_path
    expect(response.body).to include("Confirm it", "Reject it", "Open the page", "Leave it as is")

    patch decide_review_item_path(item), params: { decision: "confirm" }

    expect(company.reload.resolution_status).to eq("resolved")
    expect(item.reload).to have_attributes(status: "done", decision: "confirm", decided_by: "human:operator")
    expect(AuditEvent.where(target: item).pluck(:reasoning)).to include("Decided by hand: confirm.")
    expect(flash[:notice]).to start_with("Confirmed")
  end

  it "sets a careers page by hand, with how the operator knows" do
    company = create(:company, name: "Acme", resolution_status: "failed", resolution_failure: "blocked")
    item = item_for(company)

    patch decide_review_item_path(item), params: { decision: "set_page", url: "https://boards.greenhouse.io/acme", note: "Its jobs link there." }

    expect(company.reload).to have_attributes(resolution_status: "resolved", careers_page_url: "https://boards.greenhouse.io/acme")
    expect(item.reload).to have_attributes(status: "done", decision: "set_page", note: "Its jobs link there.")
  end

  it "records what the operator saw on a suspect answer, and needs them to say it" do
    company = create(:company, :resolved, name: "Acme")
    role = create(:posting, :suspect_negative, company: company, role_title: "Sales Engineer", job_url: "https://acme.example/jobs/7")
    item = item_for(company)

    patch decide_review_item_path(item), params: { decision: "still_listed", note: "" }
    expect(flash[:alert]).to match(/say what you saw/i)
    expect(item.reload.status).to eq("open") # a write that fails leaves it open

    patch decide_review_item_path(item), params: { decision: "still_listed", note: "Its page lists it." }
    expect(role.reload.verification_state).to eq("verified_live")
    expect(item.reload).to have_attributes(status: "done", decision: "still_listed")
  end

  it "leaves an item as is only with a note, and never raises it again for the same evidence" do
    company = create(:company, name: "Acme", resolution_status: "failed", resolution_failure: "not_found")
    item = item_for(company)

    patch decide_review_item_path(item), params: { decision: "leave", note: "" }
    expect(item.reload.status).to eq("open")

    patch decide_review_item_path(item), params: { decision: "leave", note: "No public list of roles." }
    expect(item.reload).to have_attributes(status: "left", decision: "leave", note: "No public list of roles.")

    ReviewQueue.sync!(company)
    expect(company.review_items.open).to be_empty
  end

  it "checks again in the background, the item open until the check settles it" do
    company = create(:company, name: "Acme", domain: "acme.example", resolution_status: "failed", resolution_failure: "not_found")
    item = item_for(company)

    expect { patch decide_review_item_path(item), params: { decision: "find_again" } }.to have_enqueued_job(CheckNowJob)

    expect(item.reload.status).to eq("open")
    expect(flash[:notice]).to start_with("Checking it now")

    # The item follows its check, and says when it ends whether the check settled it.
    run = company.check_runs.sole
    get review_path
    expect(response.body).to include("Waiting for the check before it to finish", "review_item_id=#{item.id}")

    run.update!(status: "done", finished_at: Time.current, summary: "No careers page found (not_found).")
    get check_run_path(run, poll: 1, review_item_id: item.id)
    expect(response.body).to include("The check didn't settle it: the item is still open.")
    expect(response.body).not_to include('data-controller="refresh"')

    company.update!(careers_page_url: "https://acme.example/careers", resolution_status: "resolved", resolution_failure: nil,
                    resolution_method: "path_probe", resolution_confidence: "high", resolved_at: Time.current)
    ReviewQueue.sync!(company)
    get check_run_path(run, poll: 1, review_item_id: item.id)
    expect(response.body).to include("The check settled it: this item is closed.")
  end

  it "refuses an item already decided, and a decision it does not know" do
    company = create(:company, kind_suggestion: "recruiter")
    item = item_for(company)

    patch decide_review_item_path(item), params: { decision: "set_kind", kind: "recruiter" }
    expect(company.reload.kind).to eq("recruiter")

    patch decide_review_item_path(item), params: { decision: "set_kind", kind: "employer" }
    expect(flash[:alert]).to eq("That item is already decided.")
    expect(company.reload.kind).to eq("recruiter")

    other = item_for(create(:company, kind_suggestion: "aggregator"))
    patch decide_review_item_path(other), params: { decision: "delete" }
    expect(flash[:alert]).to match(/unknown decision/i)
  end
end
