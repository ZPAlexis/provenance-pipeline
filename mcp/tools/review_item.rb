module ProvenanceMcp
  module Tools
    # One review item in full (2g step 3): its question, what was seen, what to check, the actions a recommendation
    # may name, and everything on record that bears on it.
    class ReviewItemDetail < ReadTool
      tool_name "get_review_item"
      title "A review item"
      description "One review item in full, by its id: its question, what was seen, what to check, the actions you may " \
                  "recommend, any recommendation already made, and everything on record that bears on it (the company's " \
                  "careers page and how it was found, what the resolver tried, its latest page reads and stated totals, " \
                  "its boards, the roles in play, and for a role, how it was last matched). Then look where the record " \
                  "can't settle it, and recommend with save_recommendation."
      input_schema(properties: { item: { type: "string", description: "The item's id" } }, required: [ "item" ])

      class << self
        def answer(item:) = ProvenanceMcp.text(Review.detail(Review.item(item)), limit: 40_000)
      end
    end
  end
end
