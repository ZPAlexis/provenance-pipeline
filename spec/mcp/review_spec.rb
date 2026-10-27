require "rails_helper"
require Rails.root.join("mcp/provenance_mcp")
ProvenanceMcp.tools
ProvenanceMcp.prompts

# The operator's own Claude client recommending decisions on the review queue (2g step 3). A read tool's or a prompt's
# call leaves the test's transaction read-only: each example writes before its first such call.
RSpec.describe "Recommending decisions on the review queue through MCP" do
  let!(:partial) { create(:company, :resolved, name: "Acme", domain: "acme.example") }
  let!(:missing) { create(:company, name: "Beta", domain: "beta.example", resolution_status: "failed", resolution_failure: "blocked") }

  def call(tool, **arguments) = ProvenanceMcp::Tools.const_get(tool).call(**arguments, server_context: nil)

  def said(response) = response.content.sole[:text]

  def raise_items
    create(:posting, company: partial, role_title: "Sales Engineer", job_url: "https://acme.example/jobs/1")
    create(:page_check, company: partial, purpose: "verification", step: nil, url: partial.careers_page_url, run_id: "r1",
                        checked_at: 1.day.ago, listings_incomplete: true, stated_total: 113, listing_count: 20, read_via: "render+llm",
                        next_page_url: "https://acme.example/careers?page=2")
    create(:posting, company: missing, role_title: "Recruiter")
    create(:page_check, company: missing, purpose: "resolution", step: "path_probe", url: "https://beta.example/careers", run_id: "r0",
                        outcome: "blocked", reason: "robots_txt", checked_at: 2.days.ago)
    [ partial, missing ].each { |company| ReviewQueue.sync!(company) }
    [ partial.review_items.open.sole, missing.review_items.open.sole ]
  end

  def recommend(item, **fields)
    as_agent("agent:assistant") do
      ReviewRecommendations.save!(item, decision: "leave", confidence: "low", reasoning: "Could not find a public list.", **fields)
    end
  end

  it "lists the open items with their counts, by kind (its name or its label), and those with no recommendation yet" do
    list, page = raise_items
    recommend(page)

    all = said(call(:ListReviewItems))
    expect(all).to start_with("Open: 2 (no careers page 1, part of a list 1).")
    expect(all).to include("- #{list.id}: [Part of a list] Is there a page listing all of Acme's roles?",
                           "- #{page.id}: [No careers page] Where does Beta list its open roles? Recommended: leave it as is (low).")
    expect(said(call(:ListReviewItems, kind: "Part of a list"))).to include("1 part of a list item:", list.id).and(not_include(page.id))
    expect(said(call(:ListReviewItems, without_recommendation: true))).to include(list.id).and(not_include(page.id))
    expect(said(call(:ListReviewItems, kind: "typo"))).to start_with("Review items are of these kinds: careers_page_candidate")
  end

  it "reads an item in full: its question, what to check, the actions it may recommend, and the record behind it, fenced" do
    list, page = raise_items

    text = said(call(:ReviewItemDetail, item: list.id))
    blocked = said(call(:ReviewItemDetail, item: page.id))

    expect(text).to include("Question: Is there a page listing all of Acme's roles?", "What to check: #{ReviewGuidance.guidance('partial_list')}",
                            "- set_page, with url:", "- leave:", "No recommendation yet.", "<evidence>\nRead 1 of 113 roles",
                            "<record>\nCompany: Acme (acme.example).", "Its latest read of the list",
                            "#{partial.careers_page_url}: ok, 20 roles via render+llm, read only in part, next page https://acme.example/careers?page=2",
                            "Sales Engineer (tracked, no answer yet", "https://acme.example/jobs/1")
    expect(text).not_to include("still_listed", "confirm:")
    expect(blocked).to include("failed: blocked", "The resolver's last search", "path_probe https://beta.example/careers: blocked (robots_txt)",
                               "- set_page, with url:", "- find_again:", "Recruiter (tracked")
    expect(said(call(:ReviewItemDetail, item: "nope"))).to start_with('No review item "nope"')
  end

  it "saves a recommendation as the assistant, under a credential for that call holding review:recommend alone" do
    list, = raise_items

    text = said(call(:SaveRecommendation, item: list.id, decision: "set_page", url: "https://boards.greenhouse.io/acme", confidence: "high",
                                          checked: [ "https://acme.example/careers", "https://boards.greenhouse.io/acme" ],
                                          reasoning: "Its careers page embeds a Greenhouse board listing all 113 roles.", model: "claude-opus-5-5"))

    expect(text).to start_with("Recommended on \"Is there a page listing all of Acme's roles?\": Set the page to https://boards.greenhouse.io/acme (high confidence).")
    expect(text).to include("/review?kind=partial_list", "Nothing is decided yet.")
    expect(list.reload).to have_attributes(status: "open", recommendation: include("by" => "agent:assistant", "model" => "claude-opus-5-5"))
    expect(AgentCredential.sole).to have_attributes(actor: "agent:assistant", scopes: %w[review:recommend], purpose: "mcp: save_recommendation",
                                                    status: "revoked")
    expect(said(call(:SaveRecommendation, item: list.id, decision: "check_again", confidence: "low", reasoning: "x")))
      .to eq("Not saved: a recommendation on part of a list is one of: set_page, leave.")
  end

  it "has a prompt that works through a kind, with its guidance, recommending and never deciding; and completes the kind" do
    raise_items

    one = ProvenanceMcp::Prompts::QueueReview.template({ kind: "partial_list", how_many: "5" }).messages.sole.to_h.dig(:content, :text)
    every = ProvenanceMcp::Prompts::QueueReview.template({}).messages.sole.to_h.dig(:content, :text)

    expect(one).to start_with("Work through 5 of my open review items of the kind part of a list, recommending a decision on each.")
    expect(one).to include("list_review_items with kind partial_list", "get_review_item", "save_recommendation", "You decide nothing",
                           "suggest I dismiss it", "- Part of a list: #{ReviewGuidance.guidance('partial_list')}")
    expect(one).not_to include("- No careers page:")
    expect(every).to include("Work through 10", "- No careers page:", "- Couldn't confirm:")
    expect(ProvenanceMcp.complete({ argument: { name: "kind", value: "page" } }))
      .to eq(completion: { values: %w[careers_page_candidate no_careers_page page_changed], hasMore: false })
  end

  it "keeps the tools' lists in step with the app's" do
    schema = ProvenanceMcp::Tools::SaveRecommendation.to_h.dig(:inputSchema, :properties)

    expect(schema.dig(:kind, :enum)).to eq(Company::KINDS)
    expect(schema.dig(:decision, :enum)).to match_array(ReviewRecommendations::ACTIONS.values.flatten.uniq)
  end
end
