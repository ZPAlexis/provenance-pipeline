require "rails_helper"

# The verifier's commands the operator runs most (1.2 to 1.5), as they run them. A check that reads a page is stood in
# for: the checks' own specs read pages.
RSpec.describe "verifier: and postings: commands" do
  let!(:company) { create(:company, :resolved, name: "Acme", domain: "acme.example") }
  let!(:role) { create(:posting, company: company, role_title: "Sales Engineer", tracking: "tracked", job_url: "https://acme.example/jobs/1") }

  def operator_events(record) = AuditEvent.where(target: record, actor: AuditEvent::OPERATOR)

  it "shows a company, and tracks, dismisses and renames as the operator, each with its note on the record" do
    expect(run_task("verifier:status", "acme").out).to include("Acme", "Sales Engineer")
    expect(run_task("verifier:status", "nobody").aborted).to start_with('No single company matches "nobody"')

    expect(run_task("verifier:dismiss", role.id, NOTE: "Not for me.").out).to eq("Backed up to #{Rails.root.join('tmp/backups/stand-in.dump')}\n" \
                                                                               "Acme / Sales Engineer: dismissed\n")
    expect(run_task("verifier:track", role.id, NOTE: "Back on the list.").out).to include("Acme / Sales Engineer: tracked")
    expect(operator_events(role).pluck(:reasoning)).to include(/Not for me\./, /Back on the list\./)

    expect(run_task("verifier:rename", company.id, COMPANY_NAME: "Acme Labs").out).to include("Acme is now Acme Labs.")
    expect(operator_events(company).sole.reasoning).to eq("Renamed by hand.")

    # Found by this spec: the name was read from NAME, which WSL sets to the machine's name, so a rename or an add
    # without one named the company after the machine.
    expect(run_task("verifier:rename", company.id, NAME: "DESKTOP-1234").aborted).to eq('Give the name in COMPANY_NAME="...".')
    expect(company.reload.name).to eq("Acme Labs")
  end

  # 4a: a company archived with its roles in play, and tracked again with them, each refusal before the backup.
  it "archives a company with its roles, and tracks it again with them, refusing before the backup" do
    expect(run_task("verifier:dismiss_company", company.id).aborted).to eq('Say why: NOTE="..." becomes the audit reasoning.')
    expect(run_task("verifier:track_company", company.id, NOTE: "Again.").aborted).to eq("Acme is already tracked.")
    expect(run_task("verifier:dismiss_company", "nope", NOTE: "x").aborted).to eq('No company "nope": its id is in its page\'s address.')

    expect(run_task("verifier:dismiss_company", company.id, NOTE: "Not hiring in my field.").out)
      .to eq("Backed up to #{Rails.root.join('tmp/backups/stand-in.dump')}\nAcme: archived, with 1 role in play archived with it\n")
    expect(role.reload.tracking).to eq("dismissed")
    expect(run_task("verifier:dismiss_company", company.id, NOTE: "Again.").aborted).to eq("Acme is already archived.")

    expect(later { run_task("verifier:track_company", company.id, NOTE: "Hiring again.") }.out).to include("Acme: tracked, with 1 role back")
    expect(role.reload.tracking).to eq("tracked")
  end

  it "records a check by hand, and undoes a verdict of the verifier's that rested on bad evidence" do
    as_agent("agent:verifier", scopes: %w[postings:verify]) do
      role.update!(verification_state: "not_found", last_checked_at: Time.current, roles_listed_count: 0)
      AuditEvent.record_write!(role, actor: "agent:verifier", reasoning: "Not among the 0 roles listed.")
    end

    expect(run_task("verifier:undo_verdict", role.id).aborted).to start_with("Say why in REASON=")
    expect(run_task("verifier:undo_verdict", role.id, REASON: "The page showed no roles: a bad read.").out)
      .to include("Acme / Sales Engineer: back to pending")
    expect(run_task("verifier:hand_check", role.id, VERDICT: "verified_live", NOTE: "Listed on its page.", ROLES: "12").out)
      .to include("Acme / Sales Engineer: verified_live, checked by hand")
    expect(role.reload).to have_attributes(verification_state: "verified_live", roles_listed_count: 12)
    expect(run_task("verifier:hand_check", role.id, VERDICT: "verified_live", ROLES: "many").aborted).to eq("ROLES must be a whole number.")
  end

  it "checks one role now, saying what it found and what it cost" do
    outcome = Verifier::CheckNow::Outcome.new(answer: "verified_live", summary: "Its own page is up and shows the role.", cost_usd: 0,
                                              run_dir: Rails.root.join("tmp/verifier/stand-in"))
    allow(Verifier::CheckNow).to receive(:role).and_return(outcome)

    checked = run_task("verifier:check", role.id)

    expect(checked.out).to include("Checking Acme / Sales Engineer: its own page first, https://acme.example/jobs/1.",
                                   "Sales Engineer: STILL LISTED", "Its own page is up and shows the role.", "Cost: est. $0.0000")
    expect(Verifier::CheckNow).to have_received(:role).with(role, worker: an_instance_of(Verifier::Worker))
    expect(run_task("verifier:check", "nope").aborted).to start_with('No posting "nope"')
  end

  it "plans a check of everything with its ceiling, running nothing without GO=1, and says what changed" do
    planned = run_task("verifier:verify")
    expect(planned.out).to include("Plan: verify 1 postings at 1 companies' watched pages.", "Nothing run. Run it with GO=1.")
    expect(DatabaseBackup).not_to have_received(:call)

    expect(run_task("verifier:changes").aborted).to be_nil
  end

  it "confirms a careers page found at low confidence, and sets a company's kind" do
    candidate = create(:company, :resolution_candidate, name: "Beta", domain: "beta.example")

    expect(run_task("verifier:candidates").out).to include(candidate.id, "Beta (beta.example)")
    expect(run_task("verifier:confirm", candidate.id).out).to include("Beta: watching #{candidate.reload.careers_page_url}")
    expect(run_task("verifier:confirm", candidate.id).aborted).to be_present
    expect(run_task("verifier:kind", candidate.id, "recruiter", REASON: "Places engineers at clients.").out).to include("Beta: recruiter")
  end

  it "moves a role to the company really hiring, one an aggregator listed" do
    moved = run_task("postings:move", role.id, "Gamma", "gamma.example", REASON: "Acme listed it for Gamma.")

    expect(moved.out).to include("Sales Engineer: Acme -> Gamma")
    expect(role.reload.company.name).to eq("Gamma")
    expect(run_task("postings:move", role.id, "Delta").aborted).to start_with("Say why in REASON=")
  end
end
