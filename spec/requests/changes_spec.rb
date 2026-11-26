require "rails_helper"

# What a check of all tracked companies found: the What changed page until 4e step 11, the audit log's Check results since.
RSpec.describe "What changed", type: :request do
  let!(:company) { create(:company, :resolved, name: "Acme", domain: "acme.example") }
  let!(:role) { create(:posting, :verified_live, company: company, role_title: "Sales Engineer") }

  def check_everything(started:, finished:)
    create(:check_run, kind: "all", company: nil, status: "done", started_at: started, finished_at: finished, total: 1)
  end

  describe "the point it compares from" do
    it "is the end of the check before the latest, or what the only check found, or the last week with none" do
      expect(WhatChanged.point).to have_attributes(key: "week")

      first = check_everything(started: 3.days.ago, finished: 3.days.ago + 40.minutes)
      expect(WhatChanged.point).to have_attributes(key: first.id, at: first.started_at)

      latest = check_everything(started: 1.hour.ago, finished: 10.minutes.ago)
      expect(WhatChanged.point).to have_attributes(key: first.id, at: first.finished_at, label: /ended/)
      expect(WhatChanged.point(latest.id)).to have_attributes(at: latest.started_at, label: /found, and since/)
    end
  end

  it "shows what changed since then in one table, newest first, each with its kind, who wrote it and why" do
    check_everything(started: 1.hour.ago, finished: 10.minutes.ago)
    as_agent("agent:verifier") do
      role.update!(verification_state: "not_found", last_checked_at: Time.current, roles_listed_count: 12)
      AuditEvent.record_write!(role, actor: "agent:verifier", reasoning: "Not among the 12 roles listed.")
      company.update!(board_vendor: "greenhouse", board_token: "acme", board_overlap: 1.0, board_evidence: "Same roles.",
                      board_confirmed_at: Time.current)
      AuditEvent.record_write!(company, actor: "agent:verifier", reasoning: "A free board lists the same roles.")
    end
    as_agent("agent:suggester") do
      suggestion = company.postings.create!(role_title: "Solutions Engineer", tracking: "suggested", fit: { "title" => "x" })
      AuditEvent.record_write!(suggestion, actor: "agent:suggester", reasoning: "Suggested: it fits.")
    end
    ReviewQueue.sync!(company)

    get audit_path(view: "checks")

    expect(response).to have_http_status(:success)
    expect(response.body).to include("What the check of", "No longer listed", "Not among the 12 roles listed.",
                                     ">Suggested</span>", "Solutions Engineer", ">Board</span>", "Greenhouse board adopted",
                                     "its credential")
    # Who wrote each, colored by kind: the app's agents teal.
    expect(response.body).to include(%(<span class="badge by-agent" title="agent:verifier">Verifier</span>),
                                     %(<span class="badge by-agent" title="agent:suggester">Suggester</span>))
    kinds = response.body[%r{<section id="checks".*?</section>}m].scan(%r{<td>\s*<span class="badge[^"]*">([^<]+)</span>}).flatten
    expect(kinds.size).to eq(3) # one table: the verdict, the suggestion, the board
  end

  it "colors who wrote each event in the audit log, a credential's agent, and the AI assistant's name" do
    Authority.unchecked do
      AuditEvent.record!(actor: AuditEvent::OPERATOR, action: "update", target: role, reasoning: "Mine.")
      AuditEvent.record!(actor: "agent:assistant", action: "update", target: role, reasoning: "On the operator's word.")
      AuditEvent.record!(actor: "system:review_queue", action: "create", target: role, reasoning: "Raised.")
    end

    get audit_path

    expect(response.body).to include(%(<span class="badge by-you" title="human:operator">Operator</span>),
                                     %(<span class="badge by-assistant" title="agent:assistant">AI assistant</span>),
                                     %(<span class="badge by-system" title="system:review_queue">Review queue</span>),
                                     %(<span class="dot by-assistant" aria-hidden="true"></span>AI assistant))
  end

  it "says when nothing changed" do
    check_everything(started: 1.minute.ago, finished: 1.minute.ago)

    get audit_path(view: "checks")

    expect(response.body).to include("Nothing changed since then.")
  end
end
