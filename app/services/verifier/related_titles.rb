module Verifier
  # Titles in the same area as a search profile's, proposed by the worker's
  # `related` command (one LLM call) for the operator to pick from: never added on
  # their own, and matching stays word by word. Each comes with how many new roles
  # it would suggest from what the watched pages last listed, counted by the same
  # rules as Preview, at no cost.
  module RelatedTitles
    # A proposed title, with the new roles it would suggest as the profile stands (and two of them).
    Proposal = Data.define(:title, :language, :reason, :adds, :examples)
    Result = Data.define(:proposals, :cost_usd, :problems)

    module_function

    # What the LLM proposes for `profile` (saved or not). Its call is recorded with its cost.
    def propose(profile, worker: Worker.new(run_dir: Worker.dir_for("related")),
                preview: ->(wider) { Suggestions.preview(wider) })
      target = { id: profile.id || "unsaved", titles: profile.titles, excluded: profile.excluded_words, places: profile.places }
      run = worker.run([ target ], command: "related")
      result = run.results.first
      problem = result ? ResultContract.related_errors(result).first : "Stopped before an answer: #{run.stopped || 'no result'}."
      cost = result ? record_call(result, run) : 0.0
      problem ||= "The AI could not propose titles (#{result['reason']})." if result && result["outcome"] != "ok"
      return Result.new(proposals: [], cost_usd: cost, problems: [ problem ]) if problem

      added = count(profile, result["proposals"].pluck("title"), preview)
      proposals = result["proposals"].map do |proposal|
        roles = added.fetch(proposal["title"], [])
        Proposal.new(title: proposal["title"], language: proposal["language"], reason: proposal["reason"],
                     adds: roles.size, examples: roles.first(2))
      end
      Result.new(proposals: proposals, cost_usd: cost, problems: [])
    end

    # The new roles each proposed title would suggest: a preview with the profile's own
    # titles first, so a role they already reach is never counted for a proposal.
    def count(profile, titles, preview)
      wider = SearchProfile.new(profile.attributes.slice("excluded_words", "places", "work_modes", "levels")
                                       .merge("titles" => profile.titles + titles))
      preview.call(wider).new_roles.group_by(&:title).transform_values do |fits|
        fits.map { |fit| "#{fit.listing['title']} at #{fit.company.name}" }
      end
    end

    # The call's evidence, as any LLM call's: what produced it and what it cost. It read no page.
    def record_call(result, run)
      llm = result["llm"]
      return 0.0 unless llm && ResultContract.llm_errors(llm).empty?

      LlmCall.create!(run_id: run.id, purpose: llm["purpose"], model: llm["model"], settings: llm["settings"] || {},
                      prompt_version: llm["prompt_version"], input_tokens: llm["input_tokens"],
                      output_tokens: llm["output_tokens"], cost_usd: llm["cost_usd"], called_at: Time.current)
      llm["cost_usd"].to_f
    end

    # What a proposal has cost, on the record; a cautious guess before the first one.
    def estimate = LlmCall.where(purpose: "relate").average(:cost_usd)&.to_f || 0.005
  end
end
