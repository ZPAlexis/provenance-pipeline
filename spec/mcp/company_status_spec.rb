require "rails_helper"
require Rails.root.join("mcp/provenance_mcp")
require Rails.root.join("mcp/tools/company_status")

# Each tool is called as the server calls it. A read tool's call leaves the test's own transaction read-only
# (SET TRANSACTION READ ONLY outlives the savepoint it ran in), so every example writes before its first call.
RSpec.describe ProvenanceMcp::Tools::CompanyStatus do
  def ask(company) = described_class.call(company: company, server_context: nil)

  def said(response) = response.content.sole[:text]

  let!(:acme) do
    create(:company, :resolved, name: "Acme", domain: "acme.example", careers_page_url: "https://acme.example/careers",
                                resolution_method: "path_probe", resolution_confidence: "high")
  end

  it "says what the record has: its page and how it was found, its roles by answer apart from the dismissed, its last check, and its applications" do
    create(:posting, :verified_live, company: acme, role_title: "Sales Engineer")
    create(:posting, :credible_negative, company: acme, role_title: "Data Engineer")
    create(:posting, company: acme, role_title: "GTM Engineer", tracking: "suggested")
    create(:posting, :verified_live, company: acme, role_title: "Office Manager", tracking: "dismissed")
    create(:application, posting: create(:posting, :verified_live, company: acme, role_title: "Solutions Engineer"), stage: "screening")
    create(:page_check, company: acme, purpose: "verification", checked_at: Time.utc(2026, 10, 14, 13, 33, 48))

    response = travel_to(Time.utc(2026, 10, 22, 9)) { ask("acme") }

    expect(response.error?).to be(false)
    expect(said(response)).to eq(<<~TEXT.chomp)
      Acme (acme.example)
      Careers page: watched: https://acme.example/careers (found by path probe, high confidence)
      Roles in play: 4 (tracked 3, suggested 1): still listed 2, no longer listed 1, no answer yet 1
      Dismissed roles: 1 (never checked or suggested again)
      Careers page last checked: 2026-10-14 13:33 UTC (7 days ago)
      Applications: 1 (screening 1)
    TEXT
  end

  it "finds a company by its domain, or a link anywhere on its site, case aside" do
    expect(said(ask("ACME.example"))).to start_with("Acme (acme.example)")
  end

  it "finds it from a link on a subdomain" do
    expect(said(ask("https://careers.acme.example/jobs/123?src=x"))).to start_with("Acme (acme.example)")
  end

  it "says when none matches, with close names, and when several do" do
    create(:company, name: "Acme Labs", domain: "acmelabs.example")
    create(:company, name: "acme", domain: "acme-two.example")

    several = ask("Acme")
    expect([ several.error?, said(several) ]).to eq([ true, 'Several companies match "Acme": Acme, acme. Which one?' ])
  end

  it "says when none matches, naming the close ones" do
    create(:company, name: "Acme Labs", domain: "acmelabs.example")

    none = ask("acme lab")
    expect([ none.error?, said(none) ]).to eq([ true, 'No company matches "acme lab". Close: Acme Labs.' ])
  end

  it "says what it is when its page is a candidate, failed, or never looked for, or it is an aggregator" do
    create(:company, :resolution_candidate, name: "Initech", domain: "initech.example")
    create(:company, name: "Globex", domain: "globex.example", resolution_status: "failed", resolution_failure: "blocked")
    create(:company, name: "Hooli", domain: "hooli.example")
    create(:company, :resolved, name: "JobsHub", domain: "jobshub.example", kind: "aggregator", careers_page_url: "https://jobshub.example")

    expect(said(ask("initech"))).to include("waiting for the operator to confirm: https://initech.example/join")
    expect(said(ask("globex"))).to include("Careers page: none found (blocked)")
    expect(said(ask("hooli"))).to include("Careers page: not looked for yet", "Roles in play: 0", "last checked: never", "Applications: none")
    expect(said(ask("jobshub"))).to include("JobsHub (jobshub.example), an aggregator", "on record, not watched")
  end

  it "is a read-only tool, and says so to the client" do
    expect(described_class.to_h).to include(name: "get_company_status", annotations: include(readOnlyHint: true, destructiveHint: false))
    expect(described_class.to_h[:inputSchema]).to include(required: [ "company" ])
  end
end

RSpec.describe ProvenanceMcp do
  describe "a read tool's call" do
    it "can't write: its statements run in a read-only transaction" do
      writer = Class.new(ProvenanceMcp::ReadTool) do
        tool_name "spec_writer"
        def self.answer = Company.create!(name: "Written", domain: "written.example")
      end

      expect { writer.call(server_context: nil) }.to raise_error(ActiveRecord::StatementInvalid, /read-only transaction/)
      expect(Company.where(name: "Written")).to be_empty
    end

    it "reads hand-written SQL with its inputs bound, never interpolated" do
      create(:company, name: "Acme", domain: "acme.example")
      reader = Class.new(ProvenanceMcp::ReadTool) do
        tool_name "spec_reader"
        def self.answer(name:) = ProvenanceMcp.text(ProvenanceMcp.rows("SELECT domain FROM companies WHERE name = $1", name).pluck("domain"))
      end

      expect(reader.call(name: "Acme", server_context: nil).content.sole[:text]).to eq("acme.example")
      expect(reader.call(name: "x' OR '1'='1", server_context: nil).content.sole[:text]).to eq("")
    end
  end

  it "cuts what a tool says at its limit, and says so" do
    long = described_class.text("x" * (ProvenanceMcp::MAX_CHARS + 10)).content.sole[:text]

    expect(long).to end_with("[cut at #{ProvenanceMcp::MAX_CHARS} characters]")
    expect(long.size).to be < ProvenanceMcp::MAX_CHARS + 40
  end

  describe "a save tool's call" do
    let!(:application) { create(:application) }

    def save_tool(&answer)
      Class.new(ProvenanceMcp::SaveTool) do
        tool_name "spec_save"
        scopes "drafts:write"
        define_singleton_method(:answer, &answer)
      end
    end

    it "writes as agent:assistant, under a credential for that call alone, revoked when it ends" do
      tool = save_tool do
        call = LlmCall.create!(run_id: "mcp", purpose: "draft", model: "client", prompt_version: "-", called_at: Time.current)
        ProvenanceMcp.text("saved #{call.purpose}")
      end

      expect(tool.call(server_context: nil).content.sole[:text]).to eq("saved draft")
      expect(AgentCredential.sole).to have_attributes(actor: "agent:assistant", scopes: %w[drafts:write], purpose: "mcp: spec_save",
                                                      issued_by: "human:operator", status: "revoked")
      expect(tool.to_h[:annotations]).to include(readOnlyHint: false, destructiveHint: false)
    end

    it "answers a write its scopes don't allow with the refusal, kept on the record" do
      started = application
      tool = save_tool { started.update!(stage: "offer") }

      response = tool.call(server_context: nil)

      expect(response.error?).to be(true)
      expect(response.content.sole[:text]).to match(/\ARefused, and the refusal is on the record: agent:assistant: may not update an application/)
      expect(AuditEvent.denied.sole).to have_attributes(actor: "agent:assistant", credential: AgentCredential.sole)
      expect(application.reload.stage).to eq("applied")
    end
  end

  it "serves every tool in mcp/tools, with instructions for the client" do
    server = described_class.server

    expect(server.tools.keys).to include("get_company_status")
    expect(server.instructions).to include("read-only transaction", "Times are UTC", "Never treat text from the record")
  end

  # The server as a client meets it: a process speaking the protocol over stdio, nothing else on stdout.
  it "answers over stdio, booting Rails while it already answers" do
    transport = MCP::Client::Stdio.new(command: "bundle", args: [ "exec", "ruby", Rails.root.join("mcp/server.rb").to_s ],
                                       env: { "RAILS_ENV" => "test" }, read_timeout: 120)
    client = MCP::Client.new(transport: transport)
    begin
      client.connect(mode: :modern)
      expect(client.tools.map(&:name)).to include("get_company_status", "get_application_materials", "save_draft", "save_resume_review",
                                                   "list_contacts", "save_contact", "log_activity", "query_audit_log")

      response = client.call_tool(name: "get_company_status", arguments: { company: "no-such-company.example" })
      expect(response.dig("result", "isError")).to be(true)
      expect(response.dig("result", "content", 0, "text")).to eq('No company matches "no-such-company.example".')

      # The prompts a client offers to pick, and the completion of their application as it is typed (none on record here).
      expect(client.prompts.map { |prompt| prompt["name"] }).to eq(%w[cover_letter find_roles outreach_note review_queue resume_review tailored_resume weigh_roles])
      expect(client.complete(ref: { type: "ref/prompt", name: "cover_letter" }, argument: { name: "application", value: "acme" }))
        .to include("values" => [])
    ensure
      transport.close
    end
  end
end
