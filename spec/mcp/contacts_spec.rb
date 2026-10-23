require "rails_helper"
require Rails.root.join("mcp/provenance_mcp")
ProvenanceMcp.tools

# Contacts and activities through MCP (2e step 2): written as agent:assistant, under a credential for each call.
# Save tools write, so these examples may write after a call; a read tool's call comes last in its example.
RSpec.describe "Contacts and activities, through MCP" do
  let!(:company) { create(:company, :resolved, name: "Acme", domain: "acme.example") }
  let!(:application) { create(:application, posting: create(:posting, company: company, role_title: "Sales Engineer"), stage: "applied") }

  def call(tool, **arguments) = ProvenanceMcp::Tools.const_get(tool).call(**arguments, server_context: nil)

  def said(response) = response.content.sole[:text]

  describe "save_contact" do
    it "adds a contact at the application's company and links it, as the assistant, its personal details audited as hashes" do
      response = call(:SaveContact, application: "acme sales", name: "Ana Lima", role: "Technical Recruiter", kind: "recruiter",
                                    email: "ana@acme.example", notes: "Wrote first on LinkedIn.")

      contact = company.contacts.sole
      expect(said(response)).to eq("Added Ana Lima (Technical Recruiter) at Acme, linked to Acme / Sales Engineer. Contact id #{contact.id}.")
      expect(application.contacts).to eq([ contact ])
      expect(AgentCredential.sole).to have_attributes(actor: "agent:assistant", scopes: %w[contacts:write], purpose: "mcp: save_contact",
                                                      status: "revoked")
      event = AuditEvent.find_by!(target: contact)
      expect(event).to have_attributes(actor: "agent:assistant", reasoning: "Contact added. Saved through MCP.")
      expect(event.changes_made.to_json).not_to include("Ana", "ana@", "LinkedIn")
    end

    it "updates a contact named by their name, and refuses the same person twice" do
      call(:SaveContact, company: "acme.example", name: "Ana Lima", kind: "recruiter")

      expect(said(call(:SaveContact, company: "Acme", name: "ana lima"))).to start_with("Ana Lima is a contact at Acme already")
      updated = call(:SaveContact, company: "Acme", contact: "ANA LIMA", role: "Head of Talent")
      expect(said(updated)).to start_with("Updated Ana Lima (Head of Talent) at Acme.")
      expect(company.contacts.sole.kind).to eq("recruiter")
    end

    it "says what it needs, and whom it can't find" do
      expect(said(call(:SaveContact, name: "Ana"))).to eq("Name the application to link it to, or the company.")
      expect(said(call(:SaveContact, company: "Acme"))).to eq("A new contact needs a name.")
      expect(said(call(:SaveContact, company: "Acme", contact: "Bruno", role: "x"))).to eq("No contact named \"Bruno\" at Acme. It has none yet.")
      expect(said(call(:SaveContact, company: "Acme", name: "Ana", email: "nope"))).to eq("Not saved: Validation failed: Email isn't an email address.")
    end
  end

  describe "log_activity" do
    let!(:contact) { Contacts.save!(company, { name: "Ana Lima", kind: "recruiter" }) }

    it "logs what happened, with a contact it links, as the assistant, and never moves the stage, saying where it points" do
      response = call(:LogActivity, application: application.id, kind: "interview", summary: "First interview booked", on: "2026-11-03",
                                    contact: "ana lima")

      activity = application.activities.sole
      expect(activity).to have_attributes(kind: "interview", occurred_on: Date.new(2026, 11, 3), contact: contact, logged_by: "agent:assistant")
      expect(application.reload).to have_attributes(stage: "applied")
      expect(application.contacts).to eq([ contact ])
      expect(said(response)).to eq("Logged on Acme / Sales Engineer: interview on 2026-11-03 with Ana Lima: First interview booked\n" \
                                   "It points to Interviewing; the application is at Applied. Only the operator moves it, on its page in " \
                                   "the app (/applications/#{application.id}).")
      expect(AgentCredential.sole).to have_attributes(scopes: %w[activities:write], purpose: "mcp: log_activity")
      expect(AuditEvent.find_by!(target: activity)).to have_attributes(actor: "agent:assistant", reasoning: "Logged through MCP.")
    end

    it "logs today when no day is given, says nothing of a stage for an email, and refuses a day that isn't one" do
      response = call(:LogActivity, application: "acme", kind: "email", summary: "Thanked Ana")

      expect(said(response)).to eq("Logged on Acme / Sales Engineer: email on #{Date.current}: Thanked Ana")
      expect(said(call(:LogActivity, application: "acme", kind: "call", summary: "x", on: "next tuesday")))
        .to eq("The day is a date like #{Date.current.iso8601}, not \"next tuesday\".")
      expect(said(call(:LogActivity, application: "acme", kind: "call", summary: "x", contact: "Bruno"))).to start_with("No contact named \"Bruno\" at Acme.")
    end

    it "gives the assistant no edit, deletion, or stage: those stay the operator's" do
      call(:LogActivity, application: "acme", kind: "email", summary: "Thanked Ana")
      activity = application.activities.sole

      expect { as_agent("agent:assistant") { activity.update!(summary: "changed") } }.to raise_error(Authority::Denied, /may not update an activity/)
      expect { as_agent("agent:assistant") { contact.destroy! } }.to raise_error(Authority::Denied, /may not destroy a contact/)
      expect { as_agent("agent:assistant") { application.update!(stage: "interviewing") } }.to raise_error(Authority::Denied, /may not update an application/)
      expect do
        as_agent("agent:assistant") { application.activities.create!(kind: "note", summary: "as someone else", occurred_on: Date.current, logged_by: "human:operator") }
      end.to raise_error(Authority::Denied, /may not create an activity/)
    end
  end

  describe "reading contacts" do
    it "lists a company's contacts and an application's, and puts the linked ones in its materials" do
      ana = Contacts.save!(company, { name: "Ana Lima", role: "Technical Recruiter", kind: "recruiter", email: "ana@acme.example",
                                      notes: "Prefers email." }, application: application)
      Contacts.save!(company, { name: "Bruno Costa", kind: "hiring_manager" })

      by_company = said(call(:ListContacts, company: "Acme"))
      by_application = said(call(:ListContacts, application: "acme sales"))
      materials = said(call(:ApplicationMaterials, application: "acme sales"))

      expect(by_company).to eq("- Ana Lima (Technical Recruiter), recruiter; ana@acme.example; linked to Sales Engineer; " \
                               "notes: Prefers email.; contact id #{ana.id}\n- Bruno Costa, hiring manager; contact id #{company.contacts.last.id}")
      expect(by_application).to start_with("- Ana Lima (Technical Recruiter)").and(not_include("Bruno"))
      expect(materials).to include("<contacts>\n- Ana Lima (Technical Recruiter), recruiter: Prefers email. (contact id #{ana.id})\n</contacts>",
                                   "Acme has 1 more (list_contacts names them).")
    end
  end

  it "keeps the tools' kinds in step with the models'" do
    expect(ProvenanceMcp::Tools::SaveContact::KINDS).to eq(Contact::KINDS)
    expect(ProvenanceMcp::Tools::LogActivity::KINDS).to eq(Activity::KINDS)
  end
end
