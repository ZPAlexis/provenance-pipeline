require "rails_helper"
require Rails.root.join("mcp/provenance_mcp")
ProvenanceMcp.tools

# A company the operator's own Claude client proposed (4b) is not tracked until the operator, or the client on their
# word, tracks it: nothing checks it, suggests its roles or asks about it, and every check that once asked "archived?"
# asks "tracked?". Chosen by hand (its link pasted, a role added there) or tracked through MCP, it is tracked, and the
# board it was proposed with is read at once, free. A read tool's call leaves the test's transaction read-only, so an
# example writes before its first read.
RSpec.describe "A company proposed and not yet tracked" do
  let!(:proposal) { create(:company, :proposed, name: "Contoso", domain: "contoso.example") }

  def call(tool, **arguments) = ProvenanceMcp::Tools.const_get(tool).call(**arguments, server_context: nil)

  def said(response) = response.content.sole[:text]

  it "is not watched: never checked, never suggested from, nothing asked about it" do
    resolved = create(:company, :proposed, :resolved, name: "Fabrikam", domain: "fabrikam.example")
    proposal.update!(resolution_status: "candidate", resolution_method: "ats_guess", resolution_confidence: "low",
                     resolution_candidate_url: "https://jobs.ashbyhq.com/contoso")

    ReviewQueue.sync!(proposal)
    expect(proposal.review_items).to be_empty
    expect(Company.watched).not_to include(resolved)
    expect(Verifier::CheckNow.refusal(proposal)).to eq("Contoso was proposed to you, not tracked: track it to check it.")
    as_agent("agent:suggester") do
      expect { resolved.postings.create!(role_title: "Solutions Engineer", tracking: "suggested", fit: { "title" => "Solutions Engineer" }) }
        .to raise_error(Authority::Denied)
    end
  end

  it "is tracked when chosen by hand, its link pasted or a role added there, its board read at once" do
    fabrikam = create(:company, :proposed, name: "Fabrikam", domain: "fabrikam.example")

    added = Verifier::Capture.company!("contoso.example")
    placed = Verifier::Capture.role!(link: "https://fabrikam.example/jobs/7", title: "Solutions Engineer", company: fabrikam)

    expect(added.note).to start_with("Contoso was proposed to you: tracked, and the board it was proposed with is read now, free.")
    expect(placed.note).to start_with("Fabrikam was proposed to you: tracked, and the board it was proposed with is read now, free.")
    expect([ proposal.reload.tracking, fabrikam.reload.tracking, placed.posting.tracking ]).to all(eq("tracked"))
    expect(CheckRun.all.map { |run| [ run.company, run.request, run.requested_by ] })
      .to contain_exactly([ proposal, { "read" => "board" }, "human:operator" ], [ fabrikam, { "read" => "board" }, "human:operator" ])
  end

  describe "through MCP" do
    let!(:fabrikam) { create(:company, :proposed, name: "Fabrikam", domain: "fabrikam.example") }
    let!(:litware) { create(:company, :proposed, name: "Litware", domain: "litware.example") }
    let!(:held) { create(:posting, company: litware, role_title: "Sales Engineer", tracking: "suggested", fit: { "title" => "Sales Engineer" }) }

    it "is tracked or declined on the operator's word, tracking reading its board as the client's request" do
      tracked = said(call(:TrackOrArchiveCompanies, companies: [ "Contoso" ], action: "track", reason: "It fits my profile."))
      declined = said(call(:TrackOrArchiveCompanies, companies: [ "Fabrikam" ], action: "archive", reason: "Not my market."))

      expect(tracked).to include("- Contoso: a proposal, tracked; the board it was proposed with is being read now, free")
      expect(declined).to include("- Fabrikam: a proposal, declined: never proposed again")
      expect(CheckRun.sole).to have_attributes(company: proposal, request: { "read" => "board" }, requested_by: "agent:assistant")
      expect(AuditEvent.where(target: fabrikam).last.reasoning)
        .to eq("Declined on the operator's word: proposed by the operator's own Claude client, archived, and never proposed again. Not my market.")
      expect(AuditEvent.where(target: proposal).last.credential.reload.scopes).to eq(%w[watchlist:curate])
    end

    it "takes a role added there as choosing it; a role there is tracked only once it is" do
      added = call(:AddRole, company: "Contoso", link: "https://contoso.example/jobs/3", title: "Solutions Engineer", reason: "Saw it on their site.")
      refused = call(:TrackOrArchiveRoles, roles: [ held.id ], action: "track", reason: "Looks good.")

      expect(said(added)).to include("Contoso was proposed to you: tracked")
      expect(proposal.reload.tracking).to eq("tracked")
      expect(CheckRun.sole.requested_by).to eq("agent:assistant")
      expect(said(refused)).to eq("Nothing changed: Litware was proposed, not tracked: track the company first, with track_or_archive_companies.")
      expect(held.reload.tracking).to eq("suggested")
    end

    it "is said to be a proposal, not watched" do
      expect(said(call(:CompanyStatus, company: "Contoso"))).to include("Contoso (contoso.example), proposed by the operator's own Claude " \
                                                                         "client: not watched until the operator tracks it, id #{proposal.id}")
      expect(said(call(:ListCompanies, tracking: "all"))).to include("- Contoso (contoso.example), proposed, id #{proposal.id}")
    end
  end

  it "lets watchlist:curate start the free board read of a company tracked, and no other run" do
    tracked = create(:company, :resolved, name: "Acme", domain: "acme.example")

    as_agent("agent:assistant", scopes: %w[watchlist:curate]) do
      expect { CheckRun.create!(kind: "company", company: tracked, requested_by: "agent:assistant", ceiling_usd: 0.5, request: {}) }
        .to raise_error(Authority::Denied)
      expect { CheckRun.create!(kind: "company", company: proposal, requested_by: "agent:assistant", ceiling_usd: 0, request: { "read" => "board" }) }
        .to raise_error(Authority::Denied)
      expect(CheckRun.create!(kind: "company", company: tracked, requested_by: "agent:assistant", ceiling_usd: 0, request: { "read" => "board" }))
        .to be_board_read
    end
  end
end
