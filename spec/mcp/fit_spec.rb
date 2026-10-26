require "rails_helper"
require Rails.root.join("mcp/provenance_mcp")
ProvenanceMcp.tools
ProvenanceMcp.prompts

# Finding roles that fit by meaning and weighing them, from the operator's own client (2f step 3). A read tool's or a
# prompt's call leaves the test's transaction read-only: each example writes before its first such call.
RSpec.describe "Finding and weighing roles through MCP" do
  let!(:company) { create(:company, :resolved, name: "Acme", domain: "acme.example") }
  let!(:profile) { SearchProfile.create!(titles: [ "Sales Engineer" ], places: [ "Brazil" ], work_modes: [ "remote" ]) }
  let!(:resume) { Resumes.keep!(profile, text: "Jordan Sample\nSales engineer, eight years.\n- Ran discovery for 35 accounts a year.") }
  let!(:read) do
    create(:page_check, company: company, purpose: "verification", step: nil, url: company.careers_page_url, run_id: "20261026T100000Z-verify",
                        checked_at: 1.day.ago, listings: [ listing("Customer Engineer", 1), listing("Recruiter", 2) ])
  end

  def listing(title, number)
    { "title" => title, "location" => "Remote - Brazil", "url" => "https://acme.example/jobs/#{number}", "work_mode" => "remote" }
  end

  def call(tool, **arguments) = ProvenanceMcp::Tools.const_get(tool).call(**arguments, server_context: nil)

  def said(response) = response.content.sole[:text]

  def describe_role(posting, text = "You will run discovery with enterprise buyers. Spanish a plus.")
    posting.role_descriptions.create!(text: text, content_hash: Resume.digest(text), read_via: "render", url: posting.job_url, run_id: "r1",
                                      first_read_at: Time.utc(2026, 10, 25, 9), last_read_at: Time.utc(2026, 10, 25, 9))
  end

  describe "find_roles" do
    def fit(title, index, company: self.company, on_record: nil)
      Verifier::Suggestions::Fit.new(company: company, listing: listing(title, index + 1), title: title, level: nil, place: "Brazil",
                                     work_mode: "remote", suggested: true, ruled_out: nil, notes: [], reasoning: "Holds #{title}.",
                                     on_record: on_record, key: "#{read.id}:#{index}")
    end

    it "weighs the stored lists by the titles the client names, with the profile's other rules, listing roles not on record" do
      beta = create(:company, :resolved, name: "Beta", domain: "beta.example")
      taken = create(:posting, company: company)
      asked = nil
      allow(Verifier::Suggestions).to receive(:preview) do |copy|
        asked = copy
        Verifier::Suggestions::Preview.new(companies: 2, unread: 0, weighed: 9, read_between: [ 2.days.ago, 1.day.ago ], problems: [],
                                           fits: [ fit("Customer Engineer", 0), fit("Solutions Consultant", 3, company: beta),
                                                   fit("Sales Engineer", 1, on_record: taken) ])
      end

      text = said(call(:FindRoles, titles: [ " Customer Engineer ", "Solutions Consultant", "" ]))

      expect(asked).to have_attributes(titles: [ "Customer Engineer", "Solutions Consultant" ], places: [ "Brazil" ], new_record?: true)
      expect(profile.reload.titles).to eq([ "Sales Engineer" ]) # the profile itself is untouched
      expect(text).to start_with("2 roles not on record holding one of: Customer Engineer, Solutions Consultant; fitting the profile's " \
                                 "places (Brazil), work modes (remote)")
      expect(text).to include("- Customer Engineer at Acme · Brazil · remote: key #{read.id}:0",
                              "- Solutions Consultant at Beta · Brazil · remote: key #{read.id}:3", "Propose the ones that may fit with suggest_roles")
      expect(text).not_to include("- Sales Engineer at Acme")
    end

    it "narrows to one company and a limit, and says what it needs" do
      allow(Verifier::Suggestions).to receive(:preview).and_return(
        Verifier::Suggestions::Preview.new(companies: 1, unread: 0, weighed: 2, read_between: [ nil, nil ], problems: [],
                                           fits: [ fit("Customer Engineer", 0), fit("Recruiter", 1) ])
      )

      expect(said(call(:FindRoles, titles: [ "Engineer" ], company: "acme", limit: 1))).to include("2 roles", "Showing 1", "Customer Engineer")
      expect(said(call(:FindRoles, titles: [ " " ]))).to eq("Name the titles to look for: the profile's (Sales Engineer) and others for the same work.")
    end
  end

  describe "suggest_roles, read_descriptions, get_roles_to_weigh and save_fit_score" do
    it "suggests the roles named as the assistant's, each with why, and says which it couldn't" do
      taken = create(:posting, company: company, role_title: "Recruiter", job_url: "https://acme.example/jobs/2")

      text = said(call(:SuggestRoles, roles: [ { key: "#{read.id}:0", why: "Customer engineering is sales engineering by another name." },
                                               { key: "#{read.id}:1", why: "x" }, { key: "nonsense", why: "x" } ]))

      suggested = company.postings.find_by!(role_title: "Customer Engineer")
      expect(suggested).to have_attributes(tracking: "suggested", fit: include("by" => "agent:assistant"))
      expect(text).to include("Suggested 1 role, as yours", "- Customer Engineer at Acme: role id #{suggested.id}",
                              "- #{read.id}:1: Recruiter at Acme is on record already (#{taken.tracking})", "read_descriptions: #{suggested.id}")
      expect(AgentCredential.sole).to have_attributes(actor: "agent:assistant", scopes: %w[postings:suggest], status: "revoked")
      expect(said(call(:SuggestRoles, roles: [ { key: "nonsense", why: "x" } ]))).to start_with("None suggested:")
    end

    it "has the verifier read descriptions, under its own credential, nothing written as the client" do
      role = create(:posting, company: company, role_title: "Customer Engineer", job_url: "https://acme.example/jobs/1")
      read_one = Verifier::Descriptions::Read.new(posting: role, outcome: "ok", summary: "read, 412 words through the Greenhouse API.",
                                                  version: nil, new_version: true)
      allow(Verifier::Descriptions).to receive(:read!).and_return([ read_one ])

      text = said(call(:ReadDescriptions, roles: [ role.id, "not-an-id" ]))

      expect(Verifier::Descriptions).to have_received(:read!).with([ role ], purpose: "mcp: read_descriptions")
      expect(text).to include("Read 1 of 1:", "- Customer Engineer at Acme (#{role.id}): read, 412 words")
      expect(said(call(:ReadDescriptions, roles: [ "not-an-id" ]))).to start_with("No role by those ids")
    end

    it "gives the fit rules, the numbered resume with its version, and the next unscored roles' descriptions, fenced as data" do
      described = create(:posting, company: company, role_title: "Customer Engineer", job_url: "https://acme.example/jobs/1")
      describe_role(described)
      unread = create(:posting, company: company, role_title: "Recruiter", job_url: "https://acme.example/jobs/2")

      text = said(call(:RolesToWeigh))
      asked = said(call(:RolesToWeigh, roles: [ described.id, unread.id ]))

      expect(text).to include(ProvenanceMcp::Writing.rules["fit"], "save_fit_score", "version=\"#{resume.version}\"",
                              "[3] - Ran discovery for 35 accounts a year.", "Role id #{described.id}: Customer Engineer at Acme (tracked).",
                              "<role_description read=\"2026-10-25\"", "You will run discovery with enterprise buyers.")
      expect(text).not_to include("Recruiter")
      expect(asked).to include("No description read yet (read_descriptions reads them, free): Recruiter at Acme (#{unread.id})")
    end

    it "saves a score as the assistant, under a credential holding fit:write, its lines read against the resume version it saw" do
      role = create(:posting, company: company, role_title: "Customer Engineer", job_url: "https://acme.example/jobs/1")
      describe_role(role)

      text = said(call(:SaveFitScore, role: role.id, resume_version: resume.version, score: 81, level: "Mid-level, as the resume shows",
                                      matches: [ { point: "Discovery", lines: [ 3, 9 ] } ], gaps: [ { asks: "Spanish", note: "Not shown." } ],
                                      why: "Discovery-led sales engineering under another name.", model: "claude-opus-5-5"))

      score = role.fit_scores.sole
      expect(text).to start_with("Saved: 81 for Customer Engineer at Acme (1 match, 1 gap); 1 line it named isn't in the resume, left out.")
      expect(score).to have_attributes(written_by: "agent:assistant", reported_model: "claude-opus-5-5", resume: resume, dropped_lines: 1,
                                       matches: [ { "point" => "Discovery", "lines" => [ { "line" => 3, "text" => "- Ran discovery for 35 accounts a year." } ] } ])
      expect(AgentCredential.sole).to have_attributes(scopes: %w[fit:write], status: "revoked")
      expect(AuditEvent.find_by!(target: score)).to have_attributes(actor: "agent:assistant", reasoning: start_with("Saved through MCP: 81"))

      expect(said(call(:SaveFitScore, role: role.id, resume_version: resume.version, score: 120, why: "x")))
        .to eq("Not saved: a score is a whole number from 0 to 100.")
      expect(said(call(:SaveFitScore, role: role.id, resume_version: "0123456789ab", score: 50, why: "x"))).to start_with("Not saved: resume version")
      expect(said(call(:SaveFitScore, role: "nope", resume_version: resume.version, score: 50, why: "x"))).to start_with("No role \"nope\"")
      unread = create(:posting, company: company, role_title: "Recruiter")
      expect(said(call(:SaveFitScore, role: unread.id, resume_version: resume.version, score: 50, why: "x")))
        .to eq("Not saved: Recruiter's description isn't read yet: read_descriptions reads it, free.")
    end
  end

  describe "the prompts" do
    it "find roles by meaning and weigh them, from the profile; and weigh the roles already offered" do
      found = ProvenanceMcp::Prompts::FindRoles.template({ focus: "customer engineering" }).messages.sole.to_h.dig(:content, :text)
      weigh = ProvenanceMcp::Prompts::WeighRoles.template({ how_many: "3" }).messages.sole.to_h.dig(:content, :text)

      expect(found).to include("judged by meaning", "find_roles", "suggest_roles", "read_descriptions", "save_fit_score",
                               "Look first for: customer engineering", "<profile>", "Titles they search for: Sales Engineer",
                               "Nothing here tracks a role")
      expect(weigh).to start_with("Weigh 3 of my roles that have no current fit score")
    end
  end

  it "gives the assistant the scopes to suggest and to weigh, never to track a role" do
    role = create(:posting, company: company, role_title: "Customer Engineer", tracking: "suggested")

    expect { as_agent("agent:assistant") { role.update!(tracking: "tracked") } }.to raise_error(Authority::Denied, /may not update a posting/)
    expect(Authority::AGENTS.dig("agent:assistant", :scopes)).to include("postings:suggest", "fit:write")
  end
end
