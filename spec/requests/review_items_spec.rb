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

  it "shows how many are waiting on the dashboard" do
    company = create(:company, resolution_status: "failed", resolution_failure: "blocked")
    ReviewQueue.sync!(company)

    get root_path

    expect(response.body).to include("To review")
  end
end
