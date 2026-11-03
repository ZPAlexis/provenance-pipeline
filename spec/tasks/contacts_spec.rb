require "rails_helper"

# The contacts' commands (2e), as the operator runs them.
RSpec.describe "contacts: commands" do
  let!(:company) { create(:company, :resolved, name: "Acme", domain: "acme.example") }
  let!(:application) { create(:application, posting: create(:posting, company: company, role_title: "Sales Engineer")) }

  it "adds a contact linked to an application, lists, changes and deletes them, each audited as the operator" do
    added = run_task("contacts:add", APPLICATION: application.id, CONTACT_NAME: "Ana Lima", KIND: "recruiter", ROLE: "Talent partner")
    contact = Contact.sole
    expect(added.out).to include("Ana Lima (Talent partner) added at Acme, linked to Acme / Sales Engineer (#{contact.id})")

    expect(run_task("contacts:list", COMPANY: "acme").out).to include("Acme", contact.id, "recruiter", "linked to: Sales Engineer")
    expect(run_task("contacts:edit", contact.id, ROLE: "Head of talent").out).to include("at Acme: changed")
    expect(contact.reload.role).to eq("Head of talent")

    expect(run_task("contacts:delete", contact.id).out).to include("Ana Lima (Head of talent) at Acme:")
    expect(Contact.count).to eq(0)
    expect(AuditEvent.where(target_type: "Contact").pluck(:actor).uniq).to eq([ AuditEvent::OPERATOR ])
  end

  it "refuses before any backup: no company named, no name, the same person twice, a kind it doesn't know" do
    expect(run_task("contacts:add", CONTACT_NAME: "Ana Lima").aborted).to start_with("Name the company in COMPANY=")
    expect(run_task("contacts:add", COMPANY: "Acme").aborted).to eq('Name them in CONTACT_NAME="...".')
    expect(run_task("contacts:add", COMPANY: "Acme", CONTACT_NAME: "Ana", KIND: "friend").aborted).to start_with("KIND is one of:")
    expect(DatabaseBackup).not_to have_received(:call)

    run_task("contacts:add", COMPANY: "Acme", CONTACT_NAME: "Ana Lima")
    expect(run_task("contacts:add", COMPANY: "Acme", CONTACT_NAME: "ana lima").aborted).to include("is a contact at Acme already")
  end
end
