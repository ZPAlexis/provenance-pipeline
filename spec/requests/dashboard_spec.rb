require "rails_helper"

RSpec.describe "Dashboard", type: :request do
  let(:company) { create(:company, :resolved, name: "Acme") }

  # 4e step 12: the verdicts that changed are the audit log's (Check results, Every write); the watch says where.
  it "counts tracked roles by answer, and leaves the verdicts that changed to the audit log" do
    role = create(:posting, :verified_live, company: company, role_title: "RevOps Engineer")
    create(:posting, company: company, tracking: "dismissed")
    role.update!(verification_state: "not_found")
    Authority.unchecked do # history, as the agent wrote it
      AuditEvent.record_write!(role, actor: "agent:verifier", reasoning: "None of the 12 roles on the page is it.")
    end
    create(:llm_call, cost_usd: 0.25)

    get root_path

    expect(response).to have_http_status(:success)
    body = response.body
    expect(body).to include("No longer listed", "Archived", "Companies watched", "$0.25")
    expect(body).to include(%(href="#{audit_path(view: "checks")}">the audit log&#39;s Check results</a>))
    expect(body).not_to include("None of the 12 roles on the page is it.")
  end

  # A run with no company (4d: a read of the operator's links) is listed by what it read, never by a company.
  it "lists a read of the operator's links among the recent checks" do
    CheckRun.start_links!.update!(status: "done", answer: "read", summary: "GitHub: 8 pages; Portfolio: 2 pages", cost_usd: 0,
                                  started_at: 1.minute.ago, finished_at: Time.current)

    get root_path

    expect(response).to have_http_status(:success)
    expect(response.body).to include(">Your links</a>", "(read free)", "GitHub: 8 pages; Portfolio: 2 pages")
  end

  it "opens on Pipeline, or on the tab its address names; a run the AI assistant asked for says so" do
    get root_path
    expect(response.body).to include(%(id="pipeline-tab" role="tab" aria-controls="pipeline" aria-selected="true"))

    CheckRun.create!(kind: "company", company: company, requested_by: "agent:assistant", ceiling_usd: 0, request: { "read" => "board" },
                     status: "done", answer: nil, summary: "12 roles read.", cost_usd: 0)
    get root_path(tab: "agents")
    expect(response.body).to include(%(id="agents-tab" role="tab" aria-controls="agents" aria-selected="true"))
    expect(response.body).to include(%(<span class="badge by-assistant" title="agent:assistant">AI assistant</span>), "(its board, read free)")
  end
end
