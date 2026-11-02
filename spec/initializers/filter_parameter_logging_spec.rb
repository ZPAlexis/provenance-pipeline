require "rails_helper"

# The record's private text stays out of the logs and out of a record printed in a console or an error page (review
# pass R3): the resume, what is written for an application, notes, pay, and other people's details.
RSpec.describe "Filtering the record's private text from the logs" do
  let(:filter) { ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters) }

  it "filters the private fields a request can carry, and only those" do
    filtered = filter.filter(
      "resume_text" => "Pat Example\nSales engineer", "body" => "Dear team", "subject" => "Hello", "guidance" => "Stress SQL",
      "notes" => "Prefers email", "note" => "Checked by hand", "comp_expectation" => "BRL 20k", "summary" => "Called the recruiter",
      "name" => "Pat Example", "role" => "Technical Recruiter", "linkedin_url" => "https://linkedin.example/in/pat",
      "email" => "pat@acme.example",
      # Not private, and left as they are:
      "kind" => "recruiter", "stage" => "applied", "title" => "Sales Engineer", "language" => "English", "url" => "https://acme.example/jobs/1",
      "decision" => "leave", "company_id" => "7c9f", "posting_id" => "1d2e"
    )

    expect(filtered.values_at("resume_text", "body", "subject", "guidance", "notes", "note", "comp_expectation", "summary", "name",
                              "role", "linkedin_url", "email")).to all(eq("[FILTERED]"))
    expect(filtered.values_at("kind", "stage", "title", "language", "url", "decision", "company_id", "posting_id"))
      .to eq([ "recruiter", "applied", "Sales Engineer", "English", "https://acme.example/jobs/1", "leave", "7c9f", "1d2e" ])
  end

  it "keeps the private text out of a record printed in a console, without hiding what isn't private" do
    expect(Resume.new(text: "Pat Example, sales engineer").inspect).not_to include("Pat Example")
    expect(Contact.new(name: "Pat Example", role: "Recruiter", notes: "Prefers email").inspect).not_to include("Pat Example", "Prefers email")
    expect(Draft.new(body: "Dear team", written_body: "Dear team", subject: "Hi", written_subject: "Hi").inspect).not_to include("Dear team", "Hi\"")
    expect(Posting.new(role_title: "Sales Engineer", roles_listed_count: 12).inspect).to include("Sales Engineer", "12")
    expect(ReviewItem.new(subject_type: "Posting").inspect).to include("Posting")
  end

  it "keeps a contact's details out of the SQL written to the log" do
    company = create(:company, :resolved, name: "Acme", domain: "acme.example")
    log = StringIO.new
    logger = ActiveRecord::Base.logger
    ActiveRecord::Base.logger = ActiveSupport::Logger.new(log)
    begin
      Authority.unchecked { company.contacts.create!(name: "Pat Example", kind: "recruiter", notes: "A private note.") }
    ensure
      ActiveRecord::Base.logger = logger
    end

    expect(log.string).to include('INSERT INTO "contacts"').and(not_include("Pat Example", "A private note."))
  end
end
