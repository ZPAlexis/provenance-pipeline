require "rails_helper"

RSpec.describe "Companies", type: :request do
  let(:company) { create(:company, :resolved, name: "Acme") }

  # 4a: the companies the operator tracks, those archived, and all; within each, what needs a look.
  it "lists the tracked companies with their domain, careers page, roles and application, and the archived apart" do
    create(:posting, :verified_live, company: company, role_title: "Sales Engineer")
    create(:posting, company: company, role_title: "Recruiter", tracking: "dismissed")
    create(:company, :resolution_candidate, name: "Maybe Corp")
    create(:company, name: "Bare Inc", resolution_status: "failed", resolution_failure: "not_found")
    quiet = create(:company, :resolved, name: "Quiet LLC")
    create(:posting, company: quiet, role_title: "Account Executive")
    create(:posting, company: quiet, role_title: "Partner Manager", verification_state: "not_found", last_checked_at: 1.day.ago)
    gone = create(:company, :resolved, name: "Gone Ltd")
    Verifier::Tracking.dismiss_company!(gone, note: "Not for me.")

    get companies_path

    expect(response).to have_http_status(:success)
    expect(response.body).to include("Tracked <span class=\"count\">4</span>", "Archived <span class=\"count\">1</span>",
                                     %(href="https://#{company.domain}"), "1 tracked", "1 still listed · 1 archived",
                                     "2 tracked", "1 gone · 1 no answer yet",
                                     "Maybe Corp", "to confirm", "Bare Inc", "none found", "Archive selected")
    expect(response.body).not_to include("Gone Ltd")
    expect(response.body).to include("No careers page yet <span class=\"count\">1</span>", "Page to confirm <span class=\"count\">1</span>",
                                     "No role tracked <span class=\"count\">2</span>", "None still listed <span class=\"count\">1</span>")

    get companies_path(filter: "to_confirm")
    expect(response.body).to include("Maybe Corp").and(not_include("Bare Inc", "Acme<"))
    # No role tracked, and roles tracked none of which is still listed: never the same company.
    get companies_path(filter: "none_tracked")
    expect(response.body).to include("Maybe Corp", "Bare Inc").and(not_include("Quiet LLC", "Acme<"))
    get companies_path(filter: "none_listed")
    expect(response.body).to include("Quiet LLC").and(not_include("Maybe Corp", "Bare Inc", "Acme<"))
    get companies_path(tab: "dismissed")
    expect(response.body).to include("Gone Ltd").and(not_include("Maybe Corp", "Archive selected"))
  end

  it "archives several companies at once under one note, each with its roles, backed up first; all or none" do
    beta = create(:company, :resolved, name: "Beta")
    role = create(:posting, company: beta, role_title: "Sales Engineer")
    applied = create(:posting, company: company, role_title: "Solutions Engineer")
    create(:application, posting: applied, company: company, stage: "applied")
    allow(DatabaseBackup).to receive(:daily)

    patch dismiss_many_companies_path, params: { ids: [ beta.id, company.id ], note: "Not for me." }
    expect(flash[:alert]).to eq("None archived: Acme has an open application (Solutions Engineer): close or withdraw it first.")
    expect(beta.reload.tracking).to eq("tracked")

    patch dismiss_many_companies_path, params: { ids: [ beta.id ], note: "Not for me." }
    expect(flash[:notice]).to eq("1 company archived, with 1 role in play: never checked, suggested from or reviewed, until you track one again.")
    expect([ beta.reload.tracking, role.reload.tracking ]).to eq(%w[dismissed dismissed])
    expect(DatabaseBackup).to have_received(:daily).twice

    patch dismiss_many_companies_path, params: { note: "x" }
    expect(flash[:alert]).to eq("Select the companies to archive first.")
  end

  it "archives a company from its page with a note, and tracks it again with its roles, or says why not" do
    role = create(:posting, company: company, role_title: "Sales Engineer")

    get company_path(company)
    expect(response.body).to include(%(href="https://#{company.domain}"), dismiss_company_path(company), "Why archive it?",
                                     "Its 1 role in play is archived with it", "How its careers page was found")

    patch dismiss_company_path(company), params: { note: " " }
    expect(flash[:alert]).to eq("Say why: the note becomes the audit reasoning.")
    patch dismiss_company_path(company), params: { note: "Not hiring." }
    expect(flash[:notice]).to start_with("Acme: archived, 1 role in play with it.")

    get company_path(company)
    expect(response.body).to include("archived", track_company_path(company), "Bring back the 1 role archived with it",
                                     "is archived: track it again to check it.")
    patch track_company_path(company), params: { note: "Hiring again.", with_roles: "1" }
    expect(flash[:notice]).to eq("Acme: tracked, 1 role back with it.")
    expect(role.reload.tracking).to eq("tracked")
  end

  it "won't offer archiving while an application there is open, and names it" do
    applied = create(:posting, company: company, role_title: "Solutions Engineer")
    application = create(:application, posting: applied, company: company, stage: "screening")

    get company_path(company)

    expect(response.body).to include("Its application for", application_path(application), "close or withdraw it before archiving")
    expect(response.body).not_to include(dismiss_company_path(company))
  end

  it "shows a company's page, board, roles, recent checks, and recent changes" do
    company.update!(board_vendor: "ashby", board_token: "acme", board_overlap: 0.97, board_evidence: "Lists the roles.",
                    board_confirmed_at: 1.day.ago)
    create(:posting, company: company, role_title: "RevOps Engineer")
    create(:page_check, company: company, purpose: "verification", read_via: "ats_api:ashby", listing_count: 40)
    Authority.unchecked do # history, as the agent wrote it
      AuditEvent.record!(actor: "agent:verifier", action: "update", target: company,
                         changes_made: { "board_vendor" => [ nil, "ashby" ] }, reasoning: "A free board lists the same roles.")
    end

    get company_path(company)

    expect(response).to have_http_status(:success)
    expect(response.body).to include("ashby/acme", "Lists the roles.", "read in place of the page", "RevOps Engineer",
                                     "Ashby API", "A free board lists the same roles.")
  end
end
