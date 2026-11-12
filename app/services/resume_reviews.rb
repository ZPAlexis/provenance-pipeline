# Reviews of the resume against an application's role (Stage 2d): saved by the operator's own Claude client
# through MCP as agent:assistant, under the credential of that one call (resume_reviews:write), read against
# the resume version the client saw; or written in the app by the drafter, with the worker's `review` (one
# LLM call, the drafter's model) under a credential for the run holding resume_reviews:write alone. Deleted
# only by the operator. Advice, never sent. Each is audited by its counts and hashes, never its text: it
# quotes the resume. A review run's targets file holds the whole resume, so it is removed when the run ends.
module ResumeReviews
  SCOPES = %w[resume_reviews:write].freeze
  # What a review costs before there is one on the record: as a draft, Opus 5.5 at medium effort.
  FIRST_ESTIMATE = 0.07

  # What one review run did, answering a check run as a check's outcome does (CheckNowJob).
  Written = Data.define(:application, :review, :summary, :cost_usd, :run_id) do
    def finished? = !review.nil?

    def answer = review ? "reviewed" : "not reviewed"

    def tally = {}
  end

  module_function

  # What a review costs, on the record; a cautious guess before the first one.
  def estimate = LlmCall.where(purpose: "review").average(:cost_usd)&.to_f || FIRST_ESTIMATE

  # Why a review can't be written as asked, in words; nil when it can. Asked before a run is queued, and again when it runs.
  def refusal(application, language: nil)
    return "a language is named in a few words" if language.to_s.strip.size > Drafts::MAX_LANGUAGE

    needs = Drafts.missing(application)
    "reviewing needs #{needs.to_sentence} first" if needs.any?
  end

  # Since 4c with the background not on the resume, its lines numbered as the app numbers the whole background.
  def target(application, language:, resume:, description:, profile:, background: nil)
    role = application.posting
    part = ReadsBackground::PARTS.fetch("resume_review")
    { id: application.id, label: "#{application.company.name} / #{role.role_title}", role_title: role.role_title,
      company: application.company.name, location: role.location, description: description.text, resume: resume.text,
      titles: profile.titles, places: profile.places, work_modes: profile.work_modes, notes: application.notes.presence,
      language: language || "English",
      not_on_resume: background ? background.lines_of(part).map { |number, line, of| { line: number, text: line, part: of } } : [] }
  end

  # Writes a review of `application`'s role as the drafter, in `language` (English when none is asked).
  def write!(application, language: nil, worker: Verifier::Worker.new(run_dir: Verifier::Worker.dir_for("review")),
             issued_by: AuditEvent::OPERATOR)
    language = language.to_s.strip.presence
    why = refusal(application, language:)
    raise ArgumentError, why if why

    profile = SearchProfile.current
    resume = profile.resumes.newest_first.first
    description = application.posting.role_descriptions.newest_first.first
    background = profile.backgrounds.newest_first.first
    background = nil unless background&.text_of(ReadsBackground::PARTS.fetch("resume_review")).present?
    Authority.run(Drafts::ACTOR, scopes: SCOPES, issued_by: issued_by,
                                 purpose: "review: resume against #{application.posting.role_title} at #{application.company.name}") do
      run = begin
        worker.run([ target(application, language:, resume:, description:, profile:, background:) ], command: "review")
      ensure
        Verifier::Worker.forget!(worker.run_dir) # its targets and results quote the resume; the record keeps what was written
      end
      record(application, run, resume:, description:, background:)
    end
  end

  # The run's one result through the contract, then kept: its LLM call whatever came of it, and the review.
  def record(application, run, resume:, description:, background: nil)
    result = run.results.first
    unless result
      return Written.new(application:, review: nil, cost_usd: 0.0, run_id: run.id,
                         summary: "Stopped before it was written: #{run.stopped || 'no result written'}.")
    end

    errors = Verifier::ResultContract.review_errors(result)
    errors << "not the application asked for" unless result["target_id"] == application.id
    return Written.new(application:, review: nil, cost_usd: 0.0, run_id: run.id, summary: "Not recorded: #{errors.join('; ')}.") if errors.any?

    call = record_call(result["llm"], run)
    cost = call ? call.cost_usd.to_f : 0.0
    unless result["outcome"] == "ok"
      return Written.new(application:, review: nil, cost_usd: cost, run_id: run.id, summary: "The AI could not write it (#{result['reason']}).")
    end

    drawn = ->(items) { Array(items).map { |item| Array(item["background_lines"]).any? ? item : item.except("background_lines") } }
    review = application.resume_reviews.create!(
      language: result["language"], strengths: drawn.call(result["strengths"]), gaps: result["gaps"], suggestions: drawn.call(result["suggestions"]),
      note: result["note"], dropped_lines: result["dropped_lines"], resume: resume, resume_hash: resume.content_hash,
      role_description: description, description_hash: description.content_hash, written_by: Drafts::ACTOR, llm_call: call, run_id: run.id,
      background: background, background_hash: background&.hash_of(ReadsBackground::PARTS.fetch("resume_review"))
    )
    summary = summary(review)
    AuditEvent.record!(actor: Drafts::ACTOR, action: "create", target: review, model_version: call&.model, reasoning: "Reviewed: #{summary}",
                       changes_made: facts(review).transform_values { |value| [ nil, value ] })
    Written.new(application:, review:, cost_usd: cost, run_id: run.id, summary: summary)
  end

  def record_call(llm, run)
    return unless llm

    LlmCall.create!(run_id: run.id, purpose: llm["purpose"], model: llm["model"], settings: llm["settings"] || {},
                    prompt_version: llm["prompt_version"], input_tokens: llm["input_tokens"],
                    output_tokens: llm["output_tokens"], cost_usd: llm["cost_usd"], called_at: Time.current)
  end

  #
  # Since 4c, read against the background version the client saw (`background_version`), a strength or a suggestion may
  # cite lines of the background not on the resume (`background_lines`): it is drawn from the background, and flagged for
  # the operator to confirm.
  def save!(application, language:, resume_version:, strengths: [], gaps: [], suggestions: [], note: nil, reported_model: nil,
            actor: "agent:assistant", background_version: nil)
    language = language.to_s.strip
    raise ArgumentError, "name the language it is written in, in a few words" if language.empty? || language.size > Drafts::MAX_LANGUAGE

    resume, description = WrittenFrom.sources!(application, resume_version)
    part = ReadsBackground::PARTS.fetch("resume_review")
    background = WrittenFrom.background_read!(background_version, part, reread: "the application's materials")
    strengths, dropped = WrittenFrom.with_lines(resume, strengths, "point", background: background, part: part)
    suggestions, dropped_too = WrittenFrom.with_lines(resume, suggestions, "change", background: background, part: part)
    raise ArgumentError, "a review says something: its strengths, gaps, or suggestions" if strengths.empty? && suggestions.empty? && Array(gaps).empty?

    review = application.resume_reviews.create!(
      language: language, strengths: strengths, gaps: WrittenFrom.gaps(gaps), suggestions: suggestions, note: note.to_s.strip.presence,
      dropped_lines: dropped + dropped_too, resume: resume, resume_hash: resume.content_hash, role_description: description,
      description_hash: description.content_hash, written_by: actor, reported_model: WrittenFrom.reported(reported_model),
      run_id: "mcp:#{Authority.credential&.id}", background: background, background_hash: background&.hash_of(part)
    )
    summary = summary(review)
    AuditEvent.record!(actor: actor, action: "create", target: review, reasoning: "Saved through MCP: #{summary}",
                       changes_made: facts(review).transform_values { |value| [ nil, value ] })
    [ review, summary ]
  end

  # The operator's deletion; its audit record keeps its counts and hashes.
  def delete!(review, actor: AuditEvent::OPERATOR)
    ApplicationRecord.transaction do
      AuditEvent.record!(actor: actor, action: "destroy", target: review, changes_made: facts(review).transform_values { |value| [ value, nil ] },
                         reasoning: "Resume review deleted on its application's page.")
      review.destroy!
    end
  end

  def summary(review)
    dropped = WrittenFrom.dropped(review.dropped_lines)
    drawn = review.from_background(review.strengths + review.suggestions).size
    flagged = "; #{drawn} drawn from your background, not on the resume, for you to confirm" if drawn.positive?
    "Resume review in #{review.language}: #{WrittenFrom.counted(review.strengths.size, 'strength')}, " \
      "#{WrittenFrom.counted(review.gaps.size, 'gap')}, #{WrittenFrom.counted(review.suggestions.size, 'suggestion')}#{flagged}#{dropped}."
  end

  # What a review's audit events say of it: its counts and hashes, never its text.
  def facts(review)
    { "language" => review.language, "strengths" => review.strengths.size, "gaps" => review.gaps.size,
      "suggestions" => review.suggestions.size, "resume_hash" => review.resume_hash, "description_hash" => review.description_hash,
      "written_by" => review.written_by, "from_background" => review.from_background(review.strengths + review.suggestions).size.nonzero?,
      "background_hash" => review.background_hash }.compact
  end

  private_class_method :facts, :record, :record_call
end
