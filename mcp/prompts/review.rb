module ProvenanceMcp
  module Prompts
    # Working through the review queue (2g step 3): the operator's own client reads each open item, looks where the
    # record can't settle it (with its own web search), and recommends a decision on each, never deciding one.
    class QueueReview < Prompt
      prompt_name "review_queue"
      title "Review the queue"
      description "Your open review items, a kind at a time: each read in full, looked into where the record can't settle " \
                  "it, and a decision recommended for you to accept or not on the Review page. Nothing is decided here."
      arguments [ MCP::Prompt::Argument.new(name: "kind", title: "Kind",
                                            description: "Optional: one kind, such as no_careers_page or partial_list (all when left out)"),
                  MCP::Prompt::Argument.new(name: "how_many", title: "How many", description: "Optional: how many items this time (10 when left out)") ]

      class << self
        def compose(kind: nil, how_many: nil, **)
          asked = ProvenanceMcp::Review.kind(kind)
          count = how_many.to_s.strip.match?(/\A\d+\z/) ? how_many.to_i.clamp(1, 50) : 10
          kinds = asked ? [ asked ] : ReviewItem::KINDS
          [ <<~TEXT.strip, guidance(kinds) ].join("\n\n")
            Work through #{count} of my open review items#{" of the kind #{ReviewGuidance.label(asked).downcase}" if asked}, recommending a decision on each. You decide nothing: I accept or decide on the Review page.
            1. Call list_review_items with #{asked ? "kind #{asked}" : 'all_kinds'} and without_recommendation, and take the oldest #{count}.
            2. For each, read it in full with get_review_item. Where the record can't settle it, look for yourself with your web search: the company's own site, where its job ads link, an ATS board (Greenhouse, Lever, Ashby, Workday, Oracle, Gupy). When you find the page that lists its roles, recommend set_page with it, even when its robots.txt keeps the app off: say so in why (its roles will then come back to me to check by hand); an ATS board the app may read is better when there is one. Recommend leave only when the company has no public list of roles at all.
            3. Save a recommendation with save_recommendation: one of the actions get_review_item lists, the url or kind it needs, your confidence, what you checked, and why in a few sentences. Recommend only what you saw; when you couldn't settle it, say so and recommend what fits that (often leave, with why, or a check), with low confidence.
            4. When the company's only role in play looks stale (on record since an import, never seen live), say so in why and suggest I dismiss it; the action you recommend stays one of the item's own.
            5. Then give me each item in a line: the company, what you recommend, and how sure you are.
          TEXT
        end

        def guidance(kinds)
          "What to check, by kind:\n" + kinds.map { |kind| "- #{ReviewGuidance.label(kind)}: #{ReviewGuidance.guidance(kind)}" }.join("\n")
        end
      end
    end
  end
end
