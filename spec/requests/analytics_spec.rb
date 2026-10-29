require "rails_helper"

RSpec.describe "Analytics", type: :request do
  let!(:company) { create(:company, :resolved, name: "Acme", domain: "acme.example") }

  # Each write a minute after the one before, as a person makes them (WSL's host steps the clock back now and then).
  def later(&block)
    @clock = (@clock || Time.current.beginning_of_day) + 1.minute
    travel_to(@clock, &block)
  end

  # Made-up applications: five started at Interested ten days ago, three of them applied to two days later, one of
  # those rejected.
  def applications
    5.times.map do |n|
      role = create(:posting, company: company, role_title: "Role #{n}")
      application = later { Pipeline.start!(role, on: 10.days.ago.to_date) }
      later { Pipeline.move!(application, "applied", on: 8.days.ago.to_date) } if n < 3
      application
    end.tap { |made| later { Pipeline.move!(made.first, "rejected", on: 1.day.ago.to_date) } }
  end

  it "shows how far applications get, how long they sit, how they end, and what is open now" do
    applications

    get analytics_path

    expect(response).to have_http_status(:success)
    expect(response.body).to include("Analytics", "5 applications started.", "How far they get", "Interested", "Applied", "60%",
                                     "How long they sit", "How they end", "Open now", "too few to say",
                                     "Reached an offer, of 3 applied (0)", "Accepted, of 1 closed (0)")
    expect(response.body).to include(%(title="3 to go on; a rate needs at least 5"))
  end

  it "takes the applications started since a day, says when there are none, and refuses a day it can't read" do
    applications

    get analytics_path(since: Date.tomorrow.to_s)
    expect(response.body).to include("No application started since #{Date.tomorrow}", "Everything")

    get analytics_path(since: "last month")
    expect(response).to redirect_to(analytics_path)
    expect(flash[:alert]).to eq('Since is a day as YYYY-MM-DD, not "last month".')
  end

  it "shows the watch and the agents: how long roles stay listed, answers week by week, freshness, cost, reads, agreement, writes" do
    role = create(:posting, :verified_live, company: company, role_title: "Sales Engineer")
    create(:audit_event, actor: "agent:verifier", target: role, action: "update", occurred_at: 2.days.ago,
                         changes_made: { "verification_state" => %w[pending verified_live] })
    read = create(:page_check, company: company, purpose: "verification", checked_at: 2.days.ago,
                               matches: [ { "posting_id" => role.id, "verdict" => "verified_live" } ])
    create(:llm_call, page_check: read, cost_usd: 0.02, called_at: 2.days.ago)

    get analytics_path

    expect(response.body).to include("The watch", "How long roles stay listed", "for the 1 role listed still", "How often answers change",
                                     "How fresh the answers are", "checked in the last 14 days", "The agents", "What the AI cost",
                                     "$0.02 over 1 call", "By day, with the running total", "Reading the watched pages",
                                     "A role confirmed listed (1 role)", "What each one wrote", "No recommendation made")
    expect(response.body).to include(audit_path(who: "agent:verifier"))
  end

  it "is linked from the dashboard once there is an application" do
    get root_path
    expect(response.body).not_to include(analytics_path)

    applications
    get root_path
    expect(response.body).to include(%(href="#{analytics_path}"))
  end
end
