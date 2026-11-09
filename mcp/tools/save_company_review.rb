module ProvenanceMcp
  module Tools
    # A company's fit as the client reviewed it (4b step 4), saved when the operator asks: as agent:assistant, under a
    # credential for this one call holding company_reviews:write, read against the preferences version the client saw.
    # It shows on the company's page and in the Companies page's Fit column; it tracks nothing, and never weighs into a
    # role's fit.
    class SaveCompanyReview < SaveTool
      tool_name "save_company_review"
      title "Save a company review"
      description "Saves how well one company fits the operator's company preferences, as you reviewed it by the rules from " \
                  "get_company_preferences: the score from 0 to 100 and why; its stage, size and business model in the " \
                  "preferences' values, its industries and the regions it operates and hires in; the facts with their " \
                  "links; one point per preference (met, missed or unknown, with the evidence); concerns, open questions " \
                  "and the sources checked. Give the preferences version from get_company_preferences. A company that " \
                  "does what they avoid is capped at 49. It tracks nothing, and never weighs into a role's fit."
      scopes "company_reviews:write"
      LINKS = { type: "array", items: { type: "string" } }.freeze
      input_schema(
        properties: {
          company: { type: "string", description: "Its id (from suggest_companies or list_companies), its name or its domain" },
          preferences_version: { type: "string", description: "The preferences version, as get_company_preferences gives it" },
          score: { type: "integer", description: "From 0 to 100, by the rules' bands" },
          why: { type: "string", description: "The one sentence that explains the score" },
          stage: { type: "string", enum: CompanyValues::STAGES },
          size: { type: "string", enum: CompanyValues::SIZES, description: "Its size in people" },
          business_model: { type: "string", enum: CompanyValues::MODELS },
          industries: { type: "array", items: { type: "string" }, description: "In the operator's words where they apply" },
          regions: { type: "array", items: { type: "string" }, description: "Where it operates and hires" },
          facts: {
            type: "array", description: "What you found, each with its links",
            items: { type: "object", properties: { about: { type: "string", description: "What it is about: sells, funding, based, technology, signals, values" },
                                                   said: { type: "string" }, sources: LINKS }, required: %w[about said] }
          },
          points: {
            type: "array", description: "One per preference",
            items: { type: "object", properties: { about: { type: "string", enum: CompanyValues::ABOUT }, preference: { type: "string" },
                                                   verdict: { type: "string", enum: CompanyValues::VERDICTS }, evidence: { type: "string" },
                                                   sources: LINKS }, required: %w[about preference verdict] }
          },
          concerns: { type: "array", items: { type: "string" }, description: "What would change the score" },
          questions: { type: "array", items: { type: "string" }, description: "What to ask or look for next" },
          sources: { type: "array", items: { type: "string" }, description: "Every page you checked" },
          model: { type: "string", description: "The model you are, as you know it (recorded as reported)" }
        },
        required: %w[company preferences_version score why points sources]
      )

      class << self
        def answer(company:, preferences_version:, score:, why:, model: nil, **given)
          found = Lookup.company(company)
          fields = given.slice(:stage, :size, :business_model, :industries, :regions, :facts, :points, :concerns, :questions, :sources)
          fields = fields.merge(facts: Array(fields[:facts]).map { |fact| WrittenFrom.plain(fact) },
                                points: Array(fields[:points]).map { |point| WrittenFrom.plain(point) })
          saved, summary = CompanyReviews.save!(found, score: score, why: why, preferences_version: preferences_version,
                                                       reported_model: model, **fields)
          ProvenanceMcp.text("Saved, company id #{found.id}: #{summary}",
                             "It shows on the company's page in the app (/companies/#{found.id}#review) and in the Companies " \
                             "page's Fit column (review id #{saved.id}). It tracks nothing: the operator tracks, declines or " \
                             "archives the company, or asks you to.")
        end
      end
    end
  end
end
