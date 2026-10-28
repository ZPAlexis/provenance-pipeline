require "rails_helper"

# The audit log, searchable (3.1): every event, narrowed by any of its filters, newest first.
RSpec.describe AuditLog do
  let!(:company) { create(:company, :resolved, name: "Acme", domain: "acme.example") }
  let!(:role) { create(:posting, company: company, role_title: "Sales Engineer") }

  def event(actor, target, action: "update", changes: {}, at: Time.current, reasoning: nil)
    create(:audit_event, actor: actor, target: target, action: action, changes_made: changes, occurred_at: at, reasoning: reasoning)
  end

  # A verifier's run that changed a verdict, an operator who tracked the role and renamed the company, an
  # earlier human's import, and a write refused.
  def history
    credential = as_agent("agent:verifier") do |run|
      AuditEvent.record!(actor: "agent:verifier", action: "update", target: role,
                         changes_made: { "verification_state" => %w[pending not_found] }, reasoning: "Not among the 12 roles listed.")
      run
    end
    AuditEvent.where(credential: credential).update_all(occurred_at: 2.days.ago) # past the guard: the run was two days ago
    event("human:operator", role, changes: { "tracking" => %w[suggested tracked] }, at: 1.day.ago)
    event("human:operator", company, changes: { "name" => %w[ACME Acme] }, at: 3.hours.ago)
    event("human:earlier", company, action: "create", changes: { "name" => [ nil, "ACME" ] }, at: 10.days.ago)
    event("agent:suggester", role, action: "denied", changes: { "tracking" => %w[suggested tracked] }, at: 1.hour.ago)
    credential
  end

  it "lists every event, newest first, and counts them" do
    history

    log = described_class.new

    expect(log.count).to eq(5)
    expect(log.events.map(&:actor)).to eq(%w[agent:suggester human:operator human:operator agent:verifier human:earlier])
    expect(log).not_to be_filtered
  end

  it "narrows by who: the operator (every human), every agent, or one actor by its name or short name" do
    history

    expect(described_class.new(who: "operator").count).to eq(3)
    expect(described_class.new(who: "human:operator").who).to eq("operator")
    expect(described_class.new(who: "agents").events.map(&:actor)).to eq(%w[agent:suggester agent:verifier])
    expect(described_class.new(who: "verifier").events.sole.reasoning).to eq("Not among the 12 roles listed.")
    expect(described_class.new(who: "agent:verifier").who).to eq("agent:verifier")
    expect(described_class.new(who: "review_queue").count).to eq(0)
    expect { described_class.new(who: "someone") }.to raise_error(ArgumentError, /unknown actor "someone": operator, agents, or one of .*verifier/)
  end

  it "narrows by the kind of record, by its name or its model's, among the kinds on record" do
    history

    expect(described_class.new(kind: "role").count).to eq(3)
    expect(described_class.new(kind: "Company").count).to eq(2)
    expect(described_class.kinds).to eq([ %w[company Company], %w[role Posting] ])
    expect { described_class.new(kind: "draft") }.to raise_error(ArgumentError, /no event on record is about a "draft": the kinds on record are company, role/)
  end

  it "narrows by the action, by its name or its word, and by an attribute changed" do
    history

    expect(described_class.new(action: "denied").events.sole.actor).to eq("agent:suggester")
    expect(described_class.new(action: "refused").action).to eq("denied")
    expect(described_class.new(attribute: "tracking").count).to eq(2)
    expect(described_class.new(attribute: "tracking", action: "update").events.sole.actor).to eq("human:operator")
    expect(described_class.attributes).to eq(%w[name tracking verification_state])
    expect(described_class.attributes("Company")).to eq(%w[name])
    expect { described_class.new(action: "edit") }.to raise_error(ArgumentError, /unknown action "edit": one of create, update, destroy, denied/)
    expect { described_class.new(attribute: "x'; drop") }.to raise_error(ArgumentError, /named as its column is/)
  end

  it "narrows by days, each taken whole (UTC), and refuses a range backwards or a day it can't read" do
    history

    expect(described_class.new(from: 1.day.ago.to_date).count).to eq(3)
    expect(described_class.new(to: 2.days.ago.to_date.to_s).count).to eq(2)
    expect(described_class.new(from: 2.days.ago.to_date, to: 2.days.ago.to_date).events.sole.actor).to eq("agent:verifier")
    expect { described_class.new(from: Date.current, to: Date.yesterday) }.to raise_error(ArgumentError, /is after to/)
    expect { described_class.new(from: "last week") }.to raise_error(ArgumentError, 'from is a day as YYYY-MM-DD, not "last week"')
  end

  it "narrows to one record, or to the credential an agent wrote under, each named by its id" do
    credential = history

    expect(described_class.new(record: company.id).count).to eq(2)
    expect(described_class.new(record: company.id).record_event.target).to eq(company)
    expect(described_class.new(credential: credential.id).events.sole.target).to eq(role)
    expect(described_class.new(credential: credential.id).credential_record).to eq(credential)
    expect { described_class.new(record: "acme") }.to raise_error(ArgumentError, 'record is an id (a uuid), not "acme"')
  end

  it "counts who wrote what the other filters keep, the operator's together, most first" do
    history

    expect(described_class.new.by_who).to eq([ [ "operator", 3 ], [ "agent:suggester", 1 ], [ "agent:verifier", 1 ] ])
    expect(described_class.new(who: "verifier", kind: "Company").by_who).to eq([ [ "operator", 2 ] ])
  end

  it "pages the events, loading what each is about with the page" do
    history
    stub_const("AuditLog::PER_PAGE", 2)
    log = described_class.new

    expect(log.pages).to eq(3)
    expect(log.page(1).map(&:actor)).to eq(%w[agent:suggester human:operator])
    expect(log.page(3).map(&:actor)).to eq(%w[human:earlier])
    expect(log.page(1).first.association(:target)).to be_loaded
  end

  it "reads each event's changes: what a create set, what a delete held, both sides of an update, JSONB key by key" do
    created = event("human:operator", company, action: "create", changes: { "name" => [ nil, "Acme" ], "enrichment" => { "Founded" => [ nil, "2001" ] } })
    deleted = event("agent:suggester", role, action: "destroy", changes: { "role_title" => [ "Sales Engineer", nil ] })
    changed = event("agent:verifier", role, changes: { "verification_state" => %w[pending not_found] })

    expect(described_class.changes(created)).to eq([ AuditLog::Change.new("name", nil, "Acme", false),
                                                     AuditLog::Change.new("enrichment.Founded", nil, "2001", false) ])
    expect(described_class.changes(deleted).sole).to have_attributes(attribute: "role_title", after: "Sales Engineer", pair: false)
    expect(described_class.changes(changed).sole).to have_attributes(before: "pending", after: "not_found", pair: true)
  end

  it "says an event in plain text, naming its record's id; any human is the operator, and a contact only its company" do
    contact = Authority.unchecked { company.contacts.create!(name: "Pat Example", kind: "recruiter") }
    renamed = event("human:earlier", contact, changes: { "notes" => [ nil, "Met at a meetup." ] }, reasoning: "Saved by hand.")
    gone = event("agent:suggester", nil, action: "destroy", changes: { "role_title" => [ "Partner Manager", nil ] })
    gone.update_columns(target_type: "Posting", target_id: SecureRandom.uuid) # a role deleted since

    expect(described_class.describe(renamed)).to eq([ "#{renamed.occurred_at.utc.strftime('%Y-%m-%d %H:%M')} UTC  operator changed "                                                       "contact at Acme [#{contact.id}]", "  Changed: notes: — → Met at a meetup.",
                                                      "  Why: Saved by hand." ])
    expect(described_class.describe(gone.reload).first).to end_with(%(agent:suggester deleted role "Partner Manager", since deleted [#{gone.target_id}]))
    expect(described_class.subject(build(:audit_event, :without_target))).to eq("a new record")
  end

  it "gives back the filters it holds, by the names a page or a command uses" do
    credential = history

    log = described_class.new(who: "verifier", kind: "Posting", action: "refused", from: "2026-10-01", credential: credential.id)

    expect(log.to_params).to eq(who: "agent:verifier", kind: "role", action: "denied", from: "2026-10-01", credential: credential.id)
    expect(log).to be_filtered
    expect(log.description).to eq("who agent:verifier, kind role, action denied, from 2026-10-01, credential #{credential.id}")
  end
end
