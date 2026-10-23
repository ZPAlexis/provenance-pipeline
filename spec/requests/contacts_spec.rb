require "rails_helper"

RSpec.describe "Contacts", type: :request do
  let!(:company) { create(:company, :resolved, name: "Acme", domain: "acme.example") }
  let!(:application) { create(:application, posting: create(:posting, company: company, role_title: "Sales Engineer")) }

  def contact_events = AuditEvent.where(target_type: "Contact").order(:occurred_at)

  def fields(**overrides)
    { name: " Ana Lima ", role: "Technical Recruiter", kind: "recruiter", email: "ana@acme.example",
      linkedin_url: "https://www.linkedin.com/in/ana-lima", notes: "Met at a meetup." }.merge(overrides)
  end

  describe "on the company's page" do
    it "adds, edits, and deletes a contact, auditing its personal details as hashes, never their values" do
      post company_contacts_path(company), params: fields
      expect(flash[:notice]).to eq("Ana Lima added.")
      contact = company.contacts.sole
      expect(contact).to have_attributes(name: "Ana Lima", role: "Technical Recruiter", kind: "recruiter", email: "ana@acme.example")

      get company_path(company)
      expect(response.body).to include("Ana Lima", "Technical Recruiter", "Recruiter", "mailto:ana@acme.example", "Met at a meetup.")

      patch company_contact_path(company, contact), params: fields(role: "Head of Talent", notes: "")
      expect(contact.reload).to have_attributes(role: "Head of Talent", notes: nil)

      delete company_contact_path(company, contact)
      expect(Contact.count).to eq(0)
      expect(contact_events.pluck(:action)).to eq(%w[create update destroy])
      expect(contact_events.pluck(:changes_made).to_json).not_to include("Ana", "ana@", "linkedin.com/in", "meetup")
      expect(contact_events.first.changes_made["name"]).to eq([ nil, Resume.digest("Ana Lima") ])
      expect(contact_events.second.changes_made).to include("role" => [ "Technical Recruiter", "Head of Talent" ])
    end

    it "refuses an email or a link that isn't one, and a contact with no name" do
      post company_contacts_path(company), params: fields(email: "not-an-email")
      expect(flash[:alert]).to eq("Not added: Validation failed: Email isn't an email address.")

      post company_contacts_path(company), params: fields(linkedin_url: "linkedin.com/in/x")
      expect(flash[:alert]).to eq("Not added: Validation failed: Linkedin url isn't a web address.")

      post company_contacts_path(company), params: fields(name: " ")
      expect(flash[:alert]).to start_with("Not added: Validation failed: Name can't be blank")
      expect(Contact.count).to eq(0)
    end
  end

  describe "on the application's page" do
    let!(:contact) { Contacts.save!(company, fields) }

    it "links a company contact, adds and links a new one, and unlinks one, which stays with the company" do
      get application_path(application)
      expect(response.body).to include("None linked yet", "Link a contact at Acme", "Ana Lima (Technical Recruiter)")

      post application_contacts_path(application), params: { contact_id: contact.id }
      expect(flash[:notice]).to eq("Ana Lima linked.")
      post application_contacts_path(application), params: fields(name: "Bruno Costa", kind: "hiring_manager", email: "", linkedin_url: "")
      expect(application.contacts.map(&:name)).to eq([ "Ana Lima", "Bruno Costa" ])
      expect(company.contacts.find_by!(name: "Bruno Costa")).to have_attributes(kind: "hiring_manager", email: nil)

      delete application_contact_path(application, contact)
      expect(flash[:notice]).to eq("Ana Lima unlinked; they stay with Acme.")
      expect(application.reload.contacts.map(&:name)).to eq([ "Bruno Costa" ])
      expect(company.contacts.count).to eq(2)
    end

    it "logs an activity with a contact, linking them, and shows it on the timeline" do
      post log_application_path(application), params: { kind: "call", summary: "Screening call", on: Date.current, contact_id: contact.id }

      activity = application.activities.sole
      expect(activity.contact).to eq(contact)
      expect(application.contacts).to eq([ contact ])
      get application_path(application)
      expect(response.body).to include("Screening call", "with Ana Lima")

      patch application_activity_path(application, activity), params: { kind: "call", summary: "Screening call", on: Date.current, contact_id: "" }
      expect(activity.reload.contact).to be_nil
    end

    it "never links a contact at another company" do
      other = Contacts.save!(create(:company, name: "Globex", domain: "globex.example"), fields(name: "Carla Dias"))

      post application_contacts_path(application), params: { contact_id: other.id }

      expect(flash[:alert]).to eq("The record you were looking for could not be found.") # not one of this company's contacts
      expect(application.contacts).to be_empty
      expect { Contacts.link!(other, application) }.to raise_error(ActiveRecord::RecordInvalid, /must be at the application's company/)
    end

    it "keeps activities when a contact is deleted, naming no one" do
      Pipeline.log!(application, kind: "email", summary: "Wrote to Ana", contact: contact)

      Contacts.delete!(contact)

      expect(application.activities.sole).to have_attributes(contact: nil, summary: "Wrote to Ana")
      expect(contact_events.last.reasoning).to eq("Contact deleted, with 1 link to applications; 1 activity no longer names it.")
    end
  end

  # The assistant writes contacts under contacts:write (2e step 2, spec/mcp/contacts_spec.rb); no other agent may.
  it "is refused to any agent without contacts:write" do
    expect { as_agent("agent:suggester") { Contacts.save!(company, fields, actor: "agent:suggester") } }
      .to raise_error(Authority::Denied, /may not create a contact/)
  end
end
