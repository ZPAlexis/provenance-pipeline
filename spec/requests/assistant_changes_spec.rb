require "rails_helper"

# 4e step 9: what the AI assistant changes on the record a page shows, said on the page while it is open. The page asks
# every 20 seconds, as a check run's frame does, from the audit log alone.
RSpec.describe "The AI assistant's changes, said on the page", type: :request do
  let!(:company) { create(:company, :resolved, name: "Acme", domain: "acme.example") }
  let!(:role) { create(:posting, :verified_live, company: company, role_title: "Sales Engineer", tracking: "tracked") }
  let!(:application) { create(:application, posting: role) }
  let(:opened) { 1.minute.ago }

  def ask(kind, record, since: opened.utc.iso8601(6)) = get(assistant_changes_path(kind, record, since: since))

  # A change on record as the assistant saved it through MCP (or as another actor did), seeded as history is.
  def saved(target = nil, actor: "agent:assistant", action: "create", at: Time.current, **fields)
    Authority.unchecked { AuditEvent.create!(actor: actor, action: action, target: target, occurred_at: at, **fields) }
  end

  it "watches each detail page from when it was opened" do
    { role_path(role) => "role/#{role.id}", application_path(application) => "application/#{application.id}",
      company_path(company) => "company/#{company.id}" }.each do |page, asked|
      get page
      expect(response.body).to include(%(<turbo-frame id="assistant_changes" src="/assistant_changes/#{asked}?since=))
    end
  end

  it "says nothing until the assistant changes what the page shows, and asks again in 20 seconds; it writes nothing" do
    saved(role, actor: AuditEvent::OPERATOR, action: "update")       # the operator's own change
    saved(role, action: "update", at: 2.minutes.ago)                  # before the page was opened
    saved(role, action: "denied")                                     # refused: nothing changed
    saved(create(:posting, company: create(:company)), action: "update") # another role

    expect { ask("role", role) }.not_to change(AuditEvent, :count)
    expect(response.body).to include(%(data-controller="poll"), %(data-poll-interval-value="20000")).and(not_include("assistant-changes"))
  end

  it "says what the assistant changed on a role's page: the role first, then its company's reviews in its header" do
    review = create(:company_review, company: company)
    saved(review)
    saved(create(:company_review, company: company))
    saved(role, action: "update", changes_made: { "tracking" => %w[suggested tracked] })

    ask("role", role)

    expect(response.body).to include("Your AI assistant changed this page since you opened it: this role and 2 company reviews.",
                                     %(data-action="reload#now"), "Refresh")
    # The same sentence whatever order the changes come in.
    changes = RecordHistory.assistant_changes(role, since: opened).to_a
    expect(RecordHistory.said(changes.reverse, role)).to eq(RecordHistory.said(changes, role))
  end

  it "says what it saved under an application, by the application's id a record keeps, and under a company" do
    saved(target_type: "Activity", target_id: SecureRandom.uuid, changes_made: { "application_id" => [ nil, application.id ] })
    ask("application", application)
    expect(response.body).to include("Your AI assistant changed this page since you opened it: an activity.")

    suggested = create(:posting, company: company, role_title: "Solutions Engineer", tracking: "suggested")
    saved(suggested)
    saved(target_type: "Contact", target_id: SecureRandom.uuid, changes_made: { "company_id" => [ nil, company.id ] })
    ask("company", company)
    expect(response.body).to include("Your AI assistant changed this page since you opened it: a role and a contact.")
  end

  it "refuses an ask with no time the page was opened, or for a page it doesn't watch; stops asking for a record gone" do
    ask("role", role, since: "yesterday")
    expect(response).to have_http_status(:bad_request)

    get "/assistant_changes/contact/#{company.id}?since=#{opened.utc.iso8601}"
    expect(response).to have_http_status(:not_found)

    get "/assistant_changes/role/#{SecureRandom.uuid}?since=#{opened.utc.iso8601}" # a suggestion withdrawn, say
    expect(response).to have_http_status(:ok)
    expect(response.body).to include(%(<turbo-frame id="assistant_changes">)).and(not_include("poll"))
  end
end
