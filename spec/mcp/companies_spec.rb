require "rails_helper"
require Rails.root.join("mcp/provenance_mcp")
ProvenanceMcp.tools
ProvenanceMcp.prompts

# Finding companies through MCP (4b step 4): the operator's own client reads what they want of a company, checks
# candidates against the record and their boards (free, recording nothing), proposes those that may fit
# (companies:suggest), reviews them (company_reviews:write), saves the preferences on the operator's word
# (company_preferences:write), and lists, reads and tracks or declines them. A read tool's or a prompt's call leaves
# the test's transaction read-only: each example writes before its first such call.
RSpec.describe "Finding companies through MCP" do
  let!(:profile) do
    SearchProfile.create!(titles: [ "Solutions Engineer" ], places: [ "Brazil" ], company_wants: "Software for revenue teams.",
                          company_avoids: "Ad tech built on tracking people.", company_stages: %w[series_a series_b], company_models: %w[b2b],
                          company_industries: [ "Fintech" ])
  end
  let!(:acme) { create(:company, :resolved, name: "Acme", domain: "acme.example") }
  let!(:tailspin) { create(:company, :resolved, name: "Tailspin", domain: "tailspin.example", tracking: "dismissed") }
  let!(:contoso) { create(:company, :proposed, name: "Contoso", domain: "contoso.example") }

  # Stands in for Verifier::Worker, run with no API key: records what it was asked, and hands back the results given.
  let(:worker_class) do
    Class.new do
      attr_reader :asked

      def initialize(results) = @results = results

      def free? = true

      def run(targets, command:, flags: [])
        @asked = { targets: targets, command: command, flags: flags }
        Verifier::Worker::Run.new(dir: Pathname.new("tmp/verifier/20261109T120000Z-#{command}"), results: @results, stopped: nil)
      end
    end
  end

  def call(tool, **arguments) = ProvenanceMcp::Tools.const_get(tool).call(**arguments, server_context: nil)

  def said(response) = response.content.sole[:text]

  def prompt(name, **arguments) = ProvenanceMcp.server.prompts.fetch(name).template(arguments).messages.sole.to_h.dig(:content, :text)

  def board(id, slug, count)
    { "kind" => "resolution", "target_id" => id, "outcome" => "resolved", "careers_page_url" => "https://jobs.ashbyhq.com/#{slug}",
      "checks" => [ { "url" => "https://jobs.ashbyhq.com/#{slug}", "checked_at" => "2026-11-09T12:00:00+00:00", "outcome" => "ok",
                      "step" => "proposal", "listing_count" => count, "listings" => Array.new(count) { |n| { "title" => "Role #{n}" } } } ] }
  end

  def fitting(id, *titles)
    { "kind" => "suggestion", "target_id" => id,
      "roles" => titles.map { |title| { "suggested" => true, "listing" => { "title" => title, "location" => "São Paulo" } } } +
                 [ { "suggested" => false, "listing" => { "title" => "Recruiter" } } ] }
  end

  def review(**given)
    { company: contoso.id, preferences_version: profile.company_preferences_version, score: 78,
      why: "Revenue software hiring in Brazil; its funding is unknown.", stage: "series_b", business_model: "b2b", industries: [ "Fintech" ],
      regions: [ "Latin America" ], facts: [ { about: "sells", said: "A forecasting tool.", sources: [ "https://contoso.example/product" ] } ],
      points: [ { about: "wants", preference: "Software for revenue teams.", verdict: "match", evidence: "Its product page." },
                { about: "stage", preference: "Series A or B", verdict: "unknown" } ],
      concerns: [ "A small team in Brazil." ], questions: [ "Is the role remote?" ], sources: [ "https://contoso.example/about" ],
      model: "claude-opus-5-5" }.merge(given)
  end

  it "takes the app's own values: the tools load before Rails boots, so they hold them as literals" do
    values = ProvenanceMcp::CompanyValues

    expect([ values::STAGES, values::SIZES, values::MODELS ])
      .to eq([ SearchProfile::COMPANY_STAGES.keys, SearchProfile::COMPANY_SIZES, SearchProfile::COMPANY_MODELS.keys ])
    expect([ values::SOURCES, values::ABOUT, values::VERDICTS, values::MAX ])
      .to eq([ Verifier::Proposals::SOURCES.keys, CompanyReview::ABOUT, CompanyReview::VERDICTS, Verifier::Proposals::MAX ])
  end

  it "offers the five tools and two prompts, each save tool under its one scope, the check recording nothing" do
    tools = ProvenanceMcp.tools.to_h { |tool| [ tool.tool_name, tool ] }

    expect(tools.fetch("get_company_preferences").ancestors).to include(ProvenanceMcp::ReadTool)
    expect(tools.fetch("save_company_preferences").scopes).to eq(%w[company_preferences:write])
    expect(tools.fetch("suggest_companies").scopes).to eq(%w[companies:suggest])
    expect(tools.fetch("save_company_review").scopes).to eq(%w[company_reviews:write])
    expect(tools.fetch("check_company").ancestors).not_to include(ProvenanceMcp::SaveTool)
    expect(tools.fetch("check_company").to_h[:annotations]).to include(readOnlyHint: true, openWorldHint: true)
    expect(ProvenanceMcp.server.prompts.keys).to include("find_companies", "review_companies")
    expect(ProvenanceMcp::INSTRUCTIONS).to include("use the find_companies prompt", "Review a company only when the person asks",
                                                   "never open it yourself", "only on the person's word", "never weigh one into the other")
  end

  describe "get_company_preferences" do
    it "gives the rules a review keeps, the preferences fenced with their version, the values, and how many are due" do
      text = said(call(:GetCompanyPreferences))

      expect(text).to start_with("Review how well each company fits what I want of a company")
      expect(text).to include("A company review weighs one company against the person's company preferences", "caps the score at 49",
                              "<profile version=\"#{profile.company_preferences_version}\">", "What they want: Software for revenue teams.",
                              "Stages: series_a (Series A), series_b (Series B)", "Business models: b2b (B2B)", "Sizes (people): (any)",
                              "Places they can work: Brazil", "its size one of 1-10, 11-50",
                              "Preferences version #{profile.company_preferences_version}: give it with each review. Due a review against them: 2")
    end

    it "says when nothing is said yet, and when there is no profile" do
      profile.update!(company_wants: nil, company_avoids: nil, company_stages: [], company_models: [], company_industries: [])

      expect(said(call(:GetCompanyPreferences))).to include("What they want: (not said)", "ask them, and save what they tell you")
    end
  end

  describe "save_company_preferences" do
    it "saves what the operator said, those fields alone, their words by a hash alone, and says what is now due" do
      response = call(:SaveCompanyPreferences, wants: "Tools for support teams.", stages: %w[seed], words_to_avoid: [ "Gambling" ])

      expect(said(response)).to start_with("Saved on the operator's word: wants, stages, words to avoid. Preferences version " \
                                           "#{profile.reload.company_preferences_version}; 2 tracked or proposed companies are due a review")
      expect(profile).to have_attributes(company_wants: "Tools for support teams.", company_stages: %w[seed], company_excluded: %w[Gambling],
                                         company_avoids: "Ad tech built on tracking people.", titles: [ "Solutions Engineer" ])
      event = AuditEvent.where(target: profile, actor: "agent:assistant").sole
      expect(event).to have_attributes(reasoning: "Company preferences saved on the operator's word.")
      expect(event.changes_made.to_json).not_to include("support teams", "Gambling")
      expect(event.credential).to have_attributes(scopes: %w[company_preferences:write], status: "revoked")

      expect(said(call(:SaveCompanyPreferences, stages: %w[seed]))).to eq("Nothing changed: the company preferences are already as given.")
      expect(said(call(:SaveCompanyPreferences, stages: %w[unicorn]))).to start_with("Not saved: company stages can only be")
      expect(call(:SaveCompanyPreferences).error?).to be(true)
    end
  end

  describe "check_company" do
    it "says which are on record and in which state, reads the boards of the rest free, and records nothing" do
      finder = worker_class.new([ board("c0", "contoso", 2), board("c1", "fabrikam", 3) ])
      weigher = worker_class.new([ fitting("c0", "Solutions Engineer"), fitting("c1") ])
      allow(Verifier::Worker).to receive(:new).and_return(finder, weigher)
      asked = [ { name: "Acme", domain: "acme.example" }, { name: "Tailspin", domain: "tailspin.example" },
                { name: "Contoso", domain: "contoso.example", link: "https://jobs.ashbyhq.com/contoso" },
                { name: "Fabrikam", domain: "fabrikam.example", link: "https://jobs.ashbyhq.com/fabrikam" },
                { name: "Northwind", domain: "northwind.example" },
                { name: "Litware", domain: "litware.example", link: "https://www.linkedin.com/company/litware/jobs" } ]

      text = nil
      expect { text = said(call(:CheckCompany, companies: asked)) }
        .not_to(change { [ Company.count, AuditEvent.count, AgentCredential.count, contoso.reload.proposal ] })

      expect(text).to start_with("Checked 6 companies, recording nothing; 2 boards read now, free.")
      expect(text).to include("- Acme (acme.example): on record as Acme, tracked, id #{acme.id}: never propose it",
                              "- Tailspin (tailspin.example): on record as Tailspin, archived, id #{tailspin.id}: never propose it",
                              "- Contoso (contoso.example): proposed already, id #{contoso.id}: proposing it again brings its why up to date\n" \
                              "  its board: https://jobs.ashbyhq.com/contoso: 2 roles, 1 fits the profile's titles; the board names the company, " \
                              "read 2026-11-09\n  fitting the profile: Solutions Engineer (São Paulo)",
                              "- Fabrikam (fabrikam.example): not on record\n  its board: https://jobs.ashbyhq.com/fabrikam: 3 roles, 0 fit",
                              "- Northwind (northwind.example): not on record\n  its board: no known board among its links",
                              "- Litware (litware.example): not checked:")
      expect(finder.asked).to include(command: "own_board", targets: [ hash_including(name: "Contoso"), hash_including(name: "Fabrikam") ])
      expect(Verifier::Worker).to have_received(:new).with(hash_including(free: true)).twice
      expect(call(:CheckCompany, companies: Array.new(11) { { name: "X", domain: "x.example" } }).error?).to be(true)
    end
  end

  describe "suggest_companies" do
    it "proposes those not on record, as the assistant under companies:suggest, refusing one on record, with what each board lists" do
      allow(Verifier::Worker).to receive(:new).and_return(worker_class.new([ board("c0", "fabrikam", 3) ]), worker_class.new([ fitting("c0", "Sales Engineer") ]))

      text = said(call(:SuggestCompanies, model: "claude-opus-5-5", companies: [
        { name: "Fabrikam", domain: "fabrikam.example", link: "https://jobs.ashbyhq.com/fabrikam", why: "Revenue software, hiring in Brazil.",
          source: "job_board_search", query: "solutions engineer brazil", links: [ "https://jobs.ashbyhq.com/fabrikam/1" ] },
        { name: "Tailspin", domain: "tailspin.example", why: "It fits.", source: "news" }
      ]))

      fabrikam = Company.find_by!(domain: "fabrikam.example")
      expect(text).to start_with("1 proposed, 0 proposed already (its why brought up to date), 1 refused.")
      expect(text).to include("- Fabrikam (fabrikam.example): proposed, id #{fabrikam.id}\n  its board: https://jobs.ashbyhq.com/fabrikam: 3 roles, 1 fits",
                              "- Tailspin: Tailspin is on record, archived (a proposal declined is never proposed again)",
                              "Review each with save_company_review")
      expect(fabrikam).to have_attributes(tracking: "suggested", careers_page_url: nil)
      expect(fabrikam.proposal).to include("why" => "Revenue software, hiring in Brazil.", "reported_model" => "claude-opus-5-5")
      event = AuditEvent.where(target: fabrikam).sole
      expect(event).to have_attributes(actor: "agent:assistant")
      expect(event.credential.scopes).to eq(%w[companies:suggest])
    end
  end

  describe "save_company_review" do
    it "saves the review as the assistant under company_reviews:write, against the preferences version it read" do
      text = said(call(:SaveCompanyReview, **review))

      saved = contoso.company_reviews.sole
      expect(text).to start_with("Saved, company id #{contoso.id}: 78, 1 met, 0 missed, 1 unknown.")
      expect(saved).to have_attributes(score: 78, stage: "series_b", reported_model: "claude-opus-5-5", industries: [ "Fintech" ])
      expect(saved.facts.sole).to eq("about" => "sells", "said" => "A forecasting tool.", "sources" => [ "https://contoso.example/product" ])
      expect(AuditEvent.find_by!(target: saved).credential.scopes).to eq(%w[company_reviews:write])
    end

    it "refuses one read against preferences changed since, an archived company, and a score over the cap" do
      expect(said(call(:SaveCompanyReview, **review(preferences_version: "000000000000"))))
        .to start_with("Not saved: the company preferences changed since you read them")
      expect(said(call(:SaveCompanyReview, **review(company: "tailspin.example")))).to eq("Not saved: Tailspin is archived: it isn't reviewed.")
      expect(said(call(:SaveCompanyReview, **review(points: [ { about: "avoids", preference: "Ad tech.", verdict: "miss" } ]))))
        .to include("Not saved:", "at most 49")
      expect(CompanyReview.count).to eq(0)
    end
  end

  describe "list_companies and get_company_status" do
    before do
      later { create(:company_review, company: acme, score: 58) }
      later { create(:company_review, company: acme, score: 81, stage: "series_b", regions: [ "Latin America" ], concerns: [ "A small team." ]) }
      contoso.update!(proposal: contoso.proposal.merge("query" => "solutions engineer brazil",
                                                       "seen" => { "board" => "https://jobs.ashbyhq.com/contoso", "roles" => 12, "fitting" => 2,
                                                                   "owner" => "confirmed", "read_at" => "2026-11-09T12:00:00+00:00" }))
      create(:company, :resolved, name: "Northwind", domain: "northwind.example")
    end

    it "lists the proposed, with where each was found and its board, and narrows by fit or what is due, best first" do
      proposed = said(call(:ListCompanies, tracking: "proposed"))
      expect(proposed).to start_with("Companies: tracked 2, proposed 1, archived 1, all 4. Of the proposed: by fit: 85 and up 0, " \
                                     "70 and up 0, 50 and up 0, not reviewed 1, stale 0, due a review 1.")
      expect(proposed).to include("- Contoso (contoso.example), id #{contoso.id}", "fit: not reviewed",
                                  "  proposed: found by a job-board search (solutions engineer brazil); its board: https://jobs.ashbyhq.com/contoso: " \
                                  "12 roles, 2 fit the profile's titles; the board names the company")

      tracked = said(call(:ListCompanies, best_first: true))
      expect(tracked).to include("by fit: 85 and up 0, 70 and up 1, 50 and up 1, not reviewed 1, stale 0, due a review 1", "fit: 81")
      expect(tracked.index("- Acme")).to be < tracked.index("- Northwind")
      expect(said(call(:ListCompanies, fit: "70_and_up"))).to include("- Acme").and(not_include("- Northwind"))
      expect(said(call(:ListCompanies, tracking: "all", fit: "due_a_review"))).to include("- Northwind", "- Contoso", "Showing 1 to 2 of 2 (due a review)")
        .and(not_include("- Acme", "- Tailspin"))
      expect(said(call(:ListCompanies, tracking: "all"))).to include("- Contoso (contoso.example), proposed, id")
      expect(call(:ListCompanies, fit: "great").error?).to be(true)
    end

    it "shows a company's proposal and its newest review in full, with the scores before it" do
      text = said(call(:CompanyStatus, company: "acme.example"))
      expect(text).to include("Company review: 81, 1 met, 0 missed, 1 unknown, by your Claude client, through MCP",
                              "  why: It sells to revenue teams and hires in Brazil; its funding is unknown.",
                              "  found: Series B; B2B; hires in Latin America", "  match, wants: Products for revenue teams. (Its product page.) [https://acme.example/product]",
                              "  unknown, stage: Series A or B", "  concern: A small team.", "  sources checked: https://acme.example/about", "  before: 58 on")

      proposal = said(call(:CompanyStatus, company: "contoso.example"))
      expect(proposal).to include("Proposed by the operator's own Claude client", "found by a job-board search (solutions engineer brazil)",
                                  "  why it may fit: Sells to revenue teams in Brazil.", "  its board when proposed: https://jobs.ashbyhq.com/contoso: 12 roles",
                                  "Company review: none")
      expect(said(call(:CompanyStatus, company: "tailspin.example"))).to include("Company review: none (an archived company is never reviewed)")
    end
  end

  describe "the prompts" do
    it "find companies from the preferences, the record and the open web, proposing and reviewing, deciding nothing" do
      create(:application, posting: create(:posting, company: acme, role_title: "Sales Engineer"), company: acme)

      text = prompt("find_companies", how_many: "3", like: "acme.example", focus: "developer tools")

      expect(text).to start_with("Find 3 companies that may fit me, and propose them for me to track or decline. You decide nothing")
      expect(text).to include("get_company_preferences", "check_company", "never propose one tracked or archived", "suggest_companies",
                              "save_company_review", "never open LinkedIn yourself", "Look first for companies like this one on my record",
                              "Acme (acme.example)", "Look for: developer tools", "What they want: Software for revenue teams.",
                              "Companies I applied to or rated well")
    end

    it "review companies: the counts, asking first which and how many; or the steps for those asked" do
      later { create(:company_review, company: acme, preferences_digest: "sha256:before") }

      asking = prompt("review_companies")
      expect(asking).to include("ask me which and how many", "- not_reviewed: 0 tracked with no review yet", "- stale: 1 whose review is stale",
                                "- proposed: 1 proposed to me and waiting")

      steps = prompt("review_companies", which: "proposed", how_many: "2")
      expect(steps).to start_with("Review 2 companies proposed to me and waiting")
      expect(steps).to include("list_companies with tracking proposed and fit due_a_review", "(1 now)", "save_company_review")
    end

    it "ask for the preferences first when none is said" do
      profile.update!(company_wants: nil, company_avoids: nil, company_stages: [], company_models: [], company_industries: [])

      expect(prompt("review_companies", which: "stale", how_many: "1")).to start_with("I haven't said what I want of a company yet")
    end
  end
end
