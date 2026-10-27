require "rails_helper"

RSpec.describe ReviewRecommendations do
  let(:missing) { create(:company, name: "Acme", domain: "acme.example", resolution_status: "failed", resolution_failure: "not_found") }
  let(:item) { ReviewQueue.sync!(missing) && missing.review_items.open.sole }

  def recommend(on = item, decision: "set_page", url: "https://acme.example/careers", confidence: "high", **fields)
    target = on # the item is raised before the assistant acts: the assistant may only recommend
    as_agent("agent:assistant") do
      described_class.save!(target, decision: decision, url: url, confidence: confidence,
                                    reasoning: "Its homepage links Careers to this page, which lists 12 roles.", **fields)
    end
  end

  it "keeps the assistant's recommendation on the open item, under review:recommend, audited as the assistant's" do
    recommend(checked: [ "https://acme.example", " https://acme.example/careers " ], reported_model: "claude-opus-5-5")

    expect(item.reload.recommendation).to include(
      "decision" => "set_page", "url" => "https://acme.example/careers", "confidence" => "high", "by" => "agent:assistant",
      "model" => "claude-opus-5-5", "checked" => [ "https://acme.example", "https://acme.example/careers" ],
      "reasoning" => "Its homepage links Careers to this page, which lists 12 roles."
    )
    expect(item).to have_attributes(status: "open", decision: nil, recommended?: true)
    event = AuditEvent.where(target: item, action: "update").sole
    expect(event).to have_attributes(actor: "agent:assistant", reasoning: "Recommended: set the page to https://acme.example/careers (high confidence).")
  end

  it "replaces an earlier recommendation, the audit keeping both" do
    recommend
    recommend(decision: "leave", url: nil, confidence: "low")

    expect(item.reload.recommendation).to include("decision" => "leave", "confidence" => "low").and(not_include("url"))
    expect(AuditEvent.where(target: item, action: "update").count).to eq(2)
  end

  it "recommends only one of the item's own actions, with what each needs, and why" do
    expect { recommend(decision: "confirm") }.to raise_error(ArgumentError, "a recommendation on no careers page is one of: set_page, find_again, leave")
    expect { recommend(confidence: "certain") }.to raise_error(ArgumentError, "confidence is one of: high, medium, low")
    expect { recommend(url: "acme.example/careers") }.to raise_error(ArgumentError, "setting a page needs its address, as https://...")
    expect { recommend(reasoning: " ") }.to raise_error(ArgumentError, /say why/)

    company = create(:company, :resolved, name: "Beta", domain: "beta.example", kind_suggestion: "recruiter")
    kind_item = ReviewQueue.sync!(company) && company.review_items.open.sole
    expect { recommend(kind_item, decision: "set_kind", url: nil, kind: "agency") }.to raise_error(ArgumentError, /one of: employer, recruiter, aggregator/)
    expect(recommend(kind_item, decision: "set_kind", url: nil, kind: "recruiter").recommendation).to include("kind" => "recruiter").and(not_include("url"))
    expect(described_class.actions("suspect_verdict")).to eq(%w[check_again undo leave]) # never what the operator saw
  end

  it "may write the recommendation alone, on an open item alone: never decide it; and no other agent may" do
    raised = item # raised before any agent acts
    expect { as_agent("agent:suggester") { raised.update!(recommendation: { "decision" => "leave" }) } }
      .to raise_error(Authority::Denied, /may not update a review item/)
    recommend
    expect { as_agent("agent:assistant") { item.update!(status: "done", decision: "set_page") } }
      .to raise_error(Authority::Denied, /may not update a review item/)

    ReviewQueue.act!(item.reload, "leave", note: "No public list.", check: nil)
    expect { as_agent("agent:assistant") { item.update!(recommendation: { "decision" => "leave" }) } }.to raise_error(Authority::Denied)
    expect { recommend }.to raise_error(ArgumentError, "that item is decided already")
  end

  describe "how it came out" do
    it "agrees when the operator does as recommended, the same page however written; differs otherwise" do
      recommend
      ReviewQueue.act!(item.reload, "set_page", url: "http://www.acme.example/careers/", note: "As recommended.", check: nil)

      expect(item.reload.recommendation["taken"]).to include("decision" => "set_page", "url" => "http://www.acme.example/careers/")
      expect(described_class.outcome(item)).to eq("agreed")

      other = create(:company, name: "Beta", domain: "beta.example", resolution_status: "failed", resolution_failure: "not_found")
      second = ReviewQueue.sync!(other) && other.review_items.open.sole
      recommend(second, decision: "find_again", url: nil)
      ReviewQueue.act!(second.reload, "leave", note: "No public list.", check: nil)
      expect(described_class.outcome(second.reload)).to eq("differed")
      expect(described_class.agreement).to eq("no_careers_page" => { "agreed" => 1, "differed" => 1 })
    end

    it "is pending while open, resolved when the record settles it first, and judged by a check the operator asked" do
      recommend(decision: "find_again", url: nil)
      expect(described_class.outcome(item.reload)).to eq("pending")

      said = ReviewQueue.act!(item, "find_again", check: ->(_company) { "Checked." })
      expect(said).to eq("Checked.")
      expect(item.reload).to have_attributes(status: "open", recommendation: include("taken" => include("decision" => "find_again")))
      expect(AuditEvent.where(target: item, actor: "human:operator").last.reasoning).to eq("Asked for a check from the queue: find again.")

      missing.update!(resolution_status: "resolved", careers_page_url: "https://acme.example/careers", resolution_method: "path_probe",
                      resolution_confidence: "high")
      ReviewQueue.sync!(missing)
      expect(item.reload).to have_attributes(status: "done", decision: "resolved")
      expect(described_class.outcome(item)).to eq("agreed") # it asked the check recommended, and the check settled it

      other = create(:company, name: "Beta", domain: "beta.example", resolution_status: "failed", resolution_failure: "not_found")
      settled = ReviewQueue.sync!(other) && other.review_items.open.sole
      recommend(settled)
      other.update!(resolution_status: "resolved", careers_page_url: "https://beta.example/jobs", resolution_method: "path_probe",
                    resolution_confidence: "high")
      ReviewQueue.sync!(other)
      expect(described_class.outcome(settled.reload)).to eq("resolved")
      expect(described_class.outcome(create(:company).review_items.new(recommendation: {}))).to be_nil
    end
  end

  # Found 2026-10-27: a hash condition on the jsonb column was read as one on an associated table, and dropped.
  it "counts only the items that carried a recommendation" do
    plain = create(:company, name: "Beta", domain: "beta.example", resolution_status: "failed", resolution_failure: "not_found")
    unrecommended = ReviewQueue.sync!(plain) && plain.review_items.open.sole
    ReviewQueue.act!(unrecommended, "leave", note: "No public list.", check: nil)
    recommend

    expect(ReviewItem.recommended).to eq([ item ])
    expect(described_class.agreement).to eq("no_careers_page" => { "pending" => 1 })
  end

  it "says a recommendation's action as a person would" do
    expect(described_class.said("decision" => "set_page", "url" => "https://acme.example/careers")).to eq("Set the page to https://acme.example/careers")
    expect(described_class.said("decision" => "check_again")).to eq("Check it again")
    expect(described_class.same_page?("https://www.Acme.example/careers/", "http://acme.example/careers")).to be(true)
  end
end
