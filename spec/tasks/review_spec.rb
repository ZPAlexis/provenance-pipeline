require "rails_helper"

# The review queue's commands (1.5e, 2g), as the operator runs them.
RSpec.describe "review: commands" do
  let!(:company) { create(:company, name: "Acme", domain: "acme.example", resolution_status: "failed", resolution_failure: "not_found") }

  it "brings the queue in line with the record, lists what waits, and decides an item as the operator" do
    expect(run_task("review:sync").out).to include("Open items: 0 -> 1.", "No careers page: 1")
    item = company.review_items.open.sole

    expect(run_task("review:list").out).to include(item.id, "Acme", "1 open. Decide one with")
    decided = run_task("review:decide", item.id, DECISION: "leave", NOTE: "They hire through a partner.")
    expect(decided.aborted).to be_nil
    expect(item.reload).to have_attributes(status: "left", decided_by: AuditEvent::OPERATOR, note: "They hire through a partner.")
    expect(run_task("review:list").aborted).to eq("Nothing to review.")
  end

  it "refuses before any backup: no decision, leaving without a note, an item decided already" do
    ReviewQueue.sync!(company)
    item = company.review_items.open.sole

    expect(run_task("review:decide", item.id).aborted).to start_with("Give DECISION=, one of:")
    expect(run_task("review:decide", item.id, DECISION: "leave").aborted).to start_with("Say why you leave it as is")
    expect(run_task("review:accept", item.id).aborted).to eq("That item carries no recommendation: decide it with review:decide.")
    expect(run_task("review:agreement").aborted).to eq("No item has carried a recommendation yet.")
    expect(DatabaseBackup).not_to have_received(:call)
  end
end
