module ProvenanceMcp
  module Tools
    # A recommended decision on an open review item (2g step 3), saved as agent:assistant under a credential for this
    # one call holding review:recommend. It decides nothing: the operator accepts it on the Review page or decides
    # otherwise, and agreement is measured.
    class SaveRecommendation < SaveTool
      tool_name "save_recommendation"
      title "Recommend a decision"
      description "Saves your recommended decision on an open review item: one of the actions get_review_item lists for " \
                  "it, with the url for set_page or the kind for set_kind, your confidence, what you checked (addresses " \
                  "or searches), and why, in a few sentences. It replaces any earlier recommendation on the item. It " \
                  "decides nothing: the operator accepts it in one click on the Review page, or decides otherwise."
      scopes "review:recommend"
      input_schema(
        properties: {
          item: { type: "string", description: "The item's id" },
          decision: { type: "string", enum: Review::ACTIONS.keys },
          url: { type: "string", description: "For set_page: the page listing all of the company's open roles" },
          kind: { type: "string", enum: %w[employer recruiter aggregator], description: "For set_kind" },
          confidence: { type: "string", enum: %w[high medium low] },
          checked: { type: "array", items: { type: "string" }, description: "What you looked at: addresses, or searches made" },
          reasoning: { type: "string", description: "What you saw, and why it leads to this decision" },
          model: { type: "string", description: "The model you are, as you know it (recorded as reported)" }
        },
        required: %w[item decision confidence reasoning]
      )

      class << self
        def answer(item:, decision:, confidence:, reasoning:, url: nil, kind: nil, checked: [], model: nil)
          found = Review.item(item)
          ReviewRecommendations.save!(found, decision: decision, url: url, kind: kind, confidence: confidence, reasoning: reasoning,
                                             checked: checked, reported_model: model, actor: ASSISTANT)
          ProvenanceMcp.text("Recommended on \"#{ReviewGuidance.question(found)}\": #{ReviewRecommendations.said(found.recommendation)} " \
                             "(#{confidence} confidence).",
                             "It shows on the item in the app's Review page (/review?kind=#{found.kind}), where the operator accepts it " \
                             "or decides otherwise. Nothing is decided yet.")
        end
      end
    end
  end
end
