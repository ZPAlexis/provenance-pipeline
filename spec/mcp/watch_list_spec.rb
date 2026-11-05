require "rails_helper"
require Rails.root.join("mcp/provenance_mcp")
ProvenanceMcp.tools

# The watch list through MCP (4a step 4): the operator's own Claude client lists the companies as the Companies page
# does, and on the operator's word tracks or archives companies and roles, adds a role, or changes a role's own page,
# as agent:assistant under a credential for that one call holding watchlist:curate. A read tool's call leaves the
# test's transaction read-only, so an example writes before its first list_companies.
RSpec.describe "The watch list through MCP" do
  let!(:acme) { create(:company, :resolved, name: "Acme", domain: "acme.example") }
  let!(:contoso) { create(:company, :resolved, name: "Contoso", domain: "contoso.example") }
  let!(:role) { create(:posting, :verified_live, company: acme, role_title: "Sales Engineer", job_url: "https://acme.example/jobs/1") }
  let!(:suggestion) { create(:posting, company: acme, role_title: "Solutions Engineer", tracking: "suggested", fit: { "title" => "Solutions Engineer" }) }

  def call(tool, **arguments) = ProvenanceMcp::Tools.const_get(tool).call(**arguments, server_context: nil)

  def said(response) = response.content.sole[:text]

  def assistant_events(record) = AuditEvent.where(target: record, actor: "agent:assistant")

  it "offers the five tools, each saving under watchlist:curate alone but the list, which only reads" do
    tools = ProvenanceMcp.tools.to_h { |tool| [ tool.tool_name, tool ] }

    expect(tools).to include("list_companies", "track_or_archive_companies", "track_or_archive_roles", "add_role", "set_role_page")
    expect(tools.fetch("list_companies").ancestors).to include(ProvenanceMcp::ReadTool)
    expect(%w[track_or_archive_companies track_or_archive_roles add_role set_role_page].map { |name| tools.fetch(name).scopes })
      .to all(eq(%w[watchlist:curate]))
    expect(ProvenanceMcp::INSTRUCTIONS).to include("Change the watch list only when the person", "tells you to, with their reason, never on your own judgment")
  end

  describe "list_companies" do
    it "lists the tracked companies as the Companies page does, each with its id, page, roles and last check" do
      create(:company, name: "Bare Inc", domain: "bare.example", resolution_status: "failed", resolution_failure: "not_found")
      Verifier::Tracking.dismiss_company!(contoso, note: "Not for me.")

      text = said(call(:ListCompanies))

      expect(text).to start_with("Companies: tracked 2, archived 1, all 3. Of the tracked: no careers page yet 1, page to confirm 0, " \
                                 "no role tracked 1, none still listed 0.\nShowing 1 to 2 of 2")
      expect(text).to include("<record>\n- Acme (acme.example), id #{acme.id}\n  careers page: watched at https://acme.example/careers; " \
                              "roles: 1 tracked, 1 suggested (1 still listed); application: none; last checked: never")
      expect(text).to include("- Bare Inc (bare.example), id", "careers page: none found; roles: none").and(not_include("Contoso"))
    end

    it "lists the archived, or those that need a look, or by words, a page at a time" do
      Verifier::Tracking.dismiss_company!(contoso, note: "Not for me.")
      create_list(:company, 3, :resolved)

      expect(said(call(:ListCompanies, tracking: "archived"))).to include("- Contoso (contoso.example), id").and(not_include("Acme"))
      expect(said(call(:ListCompanies, tracking: "all"))).to include("Contoso (contoso.example), archived, id")
      expect(said(call(:ListCompanies, needs: "no_role_tracked"))).to include("Showing 1 to 3 of 3 (no role tracked)").and(not_include("- Acme"))
      expect(said(call(:ListCompanies, find: "acme"))).to start_with('Companies matching "acme": tracked 1')
      stub_const("ProvenanceMcp::Tools::ListCompanies::PAGE", 2)
      expect(said(call(:ListCompanies))).to include("Showing 1 to 2 of 4", "Next: offset 2.")
      expect(said(call(:ListCompanies, offset: 2))).to include("Showing 3 to 4 of 4").and(not_include("Next:"))
      expect(call(:ListCompanies, needs: "stale").error?).to be(true)
    end
  end

  describe "track_or_archive_companies" do
    it "archives companies on the operator's word, with their roles, under a credential for the call" do
      response = call(:TrackOrArchiveCompanies, companies: [ "acme.example", contoso.id ], action: "archive", reason: "Not hiring in my field.")

      expect(said(response)).to start_with("2 companies archived on the operator's word, the reason on the record")
      expect(said(response)).to include("<record>\n- Acme: 2 roles archived with it\n- Contoso: 0 roles archived with it\n</record>")
      expect([ acme.reload, contoso.reload ]).to all(be_dismissed)
      expect([ role.reload.tracking, suggestion.reload.tracking ]).to eq(%w[dismissed dismissed])
      expect(assistant_events(acme).sole.reasoning).to eq("Archived on the operator's word: never checked, suggested from or reviewed again. " \
                                                         "Not hiring in my field.")
      expect(assistant_events(role).sole.reasoning).to eq("Archived with its company: Not hiring in my field.")
      expect(AgentCredential.sole).to have_attributes(actor: "agent:assistant", scopes: %w[watchlist:curate],
                                                      purpose: "mcp: track_or_archive_companies", status: "revoked")
      expect(assistant_events(acme).sole.credential).to eq(AgentCredential.sole)
    end

    it "changes none when one has an open application, leaves one already so, and tracks one again with its roles" do
      create(:application, posting: role, company: acme, stage: "applied")

      refused = call(:TrackOrArchiveCompanies, companies: %w[contoso acme], action: "archive", reason: "Pausing.")
      expect(refused.error?).to be(true)
      expect(said(refused)).to eq("Nothing changed: Acme has an open application (Sales Engineer): close or withdraw it first.")
      expect(contoso.reload).not_to be_dismissed

      later { call(:TrackOrArchiveCompanies, companies: [ "contoso" ], action: "archive", reason: "Pausing.") }
      back = later { call(:TrackOrArchiveCompanies, companies: %w[contoso acme], action: "track", reason: "Hiring again.") }
      expect(said(back)).to include("1 company tracked", "- Contoso: 0 roles back with it", "- Acme: already tracked, left as it is")
      expect(assistant_events(contoso).order(:occurred_at).last.reasoning).to eq("Tracked on the operator's word. Hiring again.")
      expect(call(:TrackOrArchiveCompanies, companies: [ "acme" ], action: "archive", reason: " ").error?).to be(true)
    end
  end

  describe "track_or_archive_roles" do
    it "tracks or archives roles on the operator's word, by id or by company and title" do
      response = call(:TrackOrArchiveRoles, roles: [ role.id, "acme solutions" ], action: "archive", reason: "Needs relocation.")

      expect(said(response)).to include("2 roles archived on the operator's word", "- Acme / Sales Engineer: archived")
      expect(assistant_events(suggestion).sole.reasoning).to eq("Archived on the operator's word: never checked or suggested again. Needs relocation.")
      later { call(:TrackOrArchiveRoles, roles: [ role.id ], action: "track", reason: "Remote after all.") }
      expect(role.reload.tracking).to eq("tracked")
    end

    it "won't track a role at an archived company, and names the roles a vague name could be" do
      Verifier::Tracking.dismiss_company!(acme, note: "Pausing.")

      held = call(:TrackOrArchiveRoles, roles: [ role.id ], action: "track", reason: "Back.")
      expect(said(held)).to eq("Nothing changed: Acme is archived: track the company first, with track_or_archive_companies.")
      vague = call(:TrackOrArchiveRoles, roles: [ "engineer" ], action: "archive", reason: "x")
      expect(said(vague)).to start_with('2 roles match "engineer": name one by its id.').and include("<record>", "Acme / Sales Engineer (archived): #{role.id}")
    end
  end

  describe "add_role" do
    it "adds a role at a company on record, tracked and never checked, with the reason on the record" do
      response = call(:AddRole, company: "contoso", link: "https://contoso.example/careers/jobs/7", title: "Partner Manager",
                                found_at: "https://www.linkedin.com/jobs/view/4099887766", reason: "Saw it on LinkedIn.")

      added = contoso.postings.sole
      expect(said(response)).to include("Partner Manager tracked.", "Role id #{added.id}, at Contoso: tracked, its answer no answer yet, never checked here")
      expect(added).to have_attributes(tracking: "tracked", verification_state: "pending", posting_url: "https://www.linkedin.com/jobs/view/4099887766")
      expect(CheckRun.count).to eq(0)
      expect(assistant_events(added).sole.reasoning).to eq("Added by URL: https://contoso.example/careers/jobs/7 " \
                                                           "(found at https://www.linkedin.com/jobs/view/4099887766). Saw it on LinkedIn.")
    end

    it "refuses without a title, a job board's link, another company's link, or at an archived company, adding nothing" do
      expect(said(call(:AddRole, company: "contoso", link: "https://contoso.example/jobs/1", title: " ", reason: "x")))
        .to eq("Give its title: nothing reads it from its page here.")
      expect(said(call(:AddRole, company: "contoso", link: "https://www.linkedin.com/jobs/view/1", title: "Recruiter", reason: "x")))
        .to start_with("Not saved: that link is on linkedin.com, a job board")
      expect(said(call(:AddRole, company: "contoso", link: "https://acme.example/jobs/9", title: "Recruiter", reason: "x")))
        .to eq("Not saved: that link is Acme's (acme.example), on record: it isn't a role at Contoso.")
      Verifier::Tracking.dismiss_company!(contoso, note: "Pausing.")
      expect(said(call(:AddRole, company: "contoso", link: "https://contoso.example/jobs/1", title: "Recruiter", reason: "x")))
        .to eq("Not saved: Contoso is archived: track it again before adding a role there.")
      expect(contoso.postings).to be_empty
    end
  end

  describe "set_role_page" do
    it "changes a role's own page on the operator's word, never to a job board's link" do
      response = call(:SetRolePage, role: role.id, link: "https://acme.example/careers/jobs/1", reason: "The old link moved.")

      expect(said(response)).to include("Its own page is now https://acme.example/careers/jobs/1 (was https://acme.example/jobs/1)")
      expect(assistant_events(role).sole.reasoning).to eq("Its own page set on the operator's word. The old link moved.")
      expect(said(call(:SetRolePage, role: role.id, link: "https://www.linkedin.com/jobs/view/1", reason: "x"))).to start_with("Not saved: that link is on linkedin.com")
    end
  end

  # What watchlist:curate never allows, whoever holds it: an application's stage, a company's name, careers page or
  # kind, a verdict, or a role added already checked. And the suggester still never tracks.
  it "refuses, on the record, every write beyond the watch list, and the suggester tracking" do
    application = create(:application, posting: role, company: acme, stage: "applied")
    curate = ->(&write) { as_agent("agent:assistant", scopes: %w[watchlist:curate], &write) }

    expect { curate.call { application.update!(stage: "interviewing") } }.to raise_error(Authority::Denied, /may not update an application/)
    expect { curate.call { acme.update!(name: "Acme Labs") } }.to raise_error(Authority::Denied, /may not update a company \(name\)/)
    expect { curate.call { acme.update!(careers_page_url: "https://acme.example/jobs") } }.to raise_error(Authority::Denied)
    expect { curate.call { role.update!(verification_state: "not_found") } }.to raise_error(Authority::Denied, /verification_state/)
    expect { curate.call { acme.postings.create!(role_title: "Checked", tracking: "tracked", verification_state: "verified_live", last_checked_at: Time.current) } }
      .to raise_error(Authority::Denied, /may not create a posting/)
    expect { curate.call { role.update!(posting_url: "https://elsewhere.example/1") } }.to raise_error(Authority::Denied) # set already: never changed
    expect { as_agent("agent:suggester") { suggestion.update!(tracking: "tracked") } }.to raise_error(Authority::Denied, /may not update a posting/)
    expect(AuditEvent.where(action: "denied").count).to eq(7)
    expect(application.reload.stage).to eq("applied")
  end
end
