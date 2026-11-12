# How well each role fits the resume (Stage 2f), weighed by the fit scorer (agent:fit_scorer) with the worker's
# `fit`: one LLM call a role (Haiku 4.5, the operator's choice), from the role's own description and the resume,
# under a credential for the run holding fit:write alone. Only when the operator asks: one role, or the unscored in a
# batch, what it could cost shown first. Every score is kept, and the newest is the one shown; a newer resume or
# description makes it stale. Audited by its score, counts and hashes, never its text: it quotes the resume. A run's
# targets file holds the whole resume, so it is removed when the run ends.
module FitScores
  ACTOR = "agent:fit_scorer"
  SCOPES = %w[fit:write].freeze
  # What a score costs before there is one on the record: Haiku 4.5, about 4k tokens in and 600 out.
  FIRST_ESTIMATE = 0.007
  # What is weighed in a batch: the roles the operator watches or was offered, unless known to be gone.
  OFFERED = %w[tracked suggested].freeze

  # What one run did, answering a check run as a check's outcome does.
  Weighed = Data.define(:scores, :unweighed, :summary, :cost_usd, :run_id) do
    def finished? = scores.any?

    def answer = scores.any? ? "weighed" : "not weighed"

    def tally = { "weighed" => scores.size, "not weighed" => unweighed.size }.select { |_, count| count.positive? }
  end

  # A role's newest score as the pages show it: with what has changed since it was weighed (empty when nothing has), and
  # (4c) whether its Background fit no longer reads the background as it is.
  Shown = Data.define(:score, :stale, :background_stale) do
    def initialize(score:, stale:, background_stale: false) = super

    def stale? = stale.any?
  end

  module_function

  # What a score costs, on the record; a cautious guess before the first one.
  def estimate = LlmCall.where(purpose: "fit").average(:cost_usd)&.to_f || FIRST_ESTIMATE

  # The roles a batch weighs: tracked or suggested, and not known to be gone.
  def offered = Posting.where(tracking: OFFERED).where.not(verification_state: "not_found")

  # The newest score of each of `postings` (all of them when none are named), by posting id.
  def newest(postings = nil)
    scores = FitScore.select("DISTINCT ON (fit_scores.posting_id) fit_scores.*").order(:posting_id, created_at: :desc)
    scores = scores.where(posting_id: postings) if postings
    scores.index_by(&:posting_id)
  end

  # The newest score of each of `postings` that has one, by posting id, with whether the resume or its description has
  # changed since.
  def shown(postings)
    profile = SearchProfile.current
    resume = profile&.resumes&.newest_first&.first
    background = profile&.backgrounds&.newest_first&.first
    descriptions = RoleDescription.where(posting: postings).select(:id, :posting_id, :content_hash, :first_read_at, :created_at)
                                  .newest_first.group_by(&:posting_id) # their hashes, not their text
    newest(postings).transform_values do |score|
      Shown.new(score:, stale: score.stale_for(resume, descriptions[score.posting_id]&.first), background_stale: score.background_stale_for(background))
    end
  end

  # Those of `postings` weighed before the background as it is now (4c): a score, but no Background fit read against
  # it. None while no background is saved.
  def before_background(postings)
    background = SearchProfile.current&.backgrounds&.newest_first&.first or return []
    scores = newest(postings.map(&:id))
    postings.select { |posting| (score = scores[posting.id]) && (!score.background_reading? || score.background_stale_for(background)) }
  end

  # Those of `postings` with no score yet, or whose newest is stale: the resume or the description changed since.
  def unscored(postings)
    scores = shown(postings)
    postings.reject { |posting| scores[posting.id] && !scores[posting.id].stale? }
  end

  # Those of `postings` whose description is on record, or can be read first: a page of their own.
  def weighable(postings)
    described = RoleDescription.where(posting: postings).distinct.pluck(:posting_id)
    postings.select { |posting| posting.job_url.present? || described.include?(posting.id) }
  end

  # Those of `postings` whose description can be read before weighing (a page of their own) but isn't on record yet.
  def undescribed(postings)
    described = RoleDescription.where(posting: postings).distinct.pluck(:posting_id)
    postings.select { |posting| posting.job_url.present? && !described.include?(posting.id) }
  end

  # Why `postings` can't be weighed as a whole, in words; nil when they can (each still needs its own description).
  def refusal(postings)
    return "name a role to weigh" if postings.empty?

    "weighing needs a resume, saved on the Profile page, first" unless SearchProfile.current&.resumes&.exists?
  end

  # Since 4c with the operator's background, every part numbered as the app numbers it, for the Background fit.
  def target(posting, resume:, description:, profile:, background: nil)
    { id: posting.id, label: "#{posting.company.name} / #{posting.role_title}", role_title: posting.role_title,
      company: posting.company.name, location: posting.location, description: description.text, resume: resume.text,
      titles: profile.titles,
      background: background ? background.numbered_lines.map { |number, line, part| { line: number, text: line, part: part } } : [] }
  end

  # Weighs each of `postings` against the newest resume as the fit scorer, from its newest description; a role with
  # no description on record is left unweighed, and says so.
  def weigh!(postings, worker: Verifier::Worker.new(run_dir: Verifier::Worker.dir_for("fit")), issued_by: AuditEvent::OPERATOR)
    postings = Array(postings)
    why = refusal(postings)
    raise ArgumentError, why if why

    profile = SearchProfile.current
    resume = profile.resumes.newest_first.first
    background = profile.backgrounds.newest_first.first
    descriptions = postings.index_with { |posting| posting.role_descriptions.newest_first.first }
    unweighed = postings.reject { |posting| descriptions[posting] }.map { |posting| [ posting, "no description on record" ] }
    ready = postings.select { |posting| descriptions[posting] }
    return weighed([], unweighed, 0.0, nil, nil) if ready.empty?

    purpose = ready.one? ? "fit: #{ready.first.role_title} at #{ready.first.company.name}" : "fit: #{ready.size} roles"
    Authority.run(ACTOR, scopes: SCOPES, purpose: purpose, ttl: ready.one? ? Authority::ONE : Authority::BATCH, issued_by: issued_by) do
      run = begin
        worker.run(ready.map { |posting| target(posting, resume:, description: descriptions[posting], profile:, background:) }, command: "fit")
      ensure
        Verifier::Worker.forget!(worker.run_dir) # its targets and results quote the resume; the record keeps what was written
      end
      by_id = ready.index_by(&:id)
      scores, cost = [], 0.0
      run.results.each do |result|
        posting = by_id.delete(result["target_id"]) if result.is_a?(Hash)
        score, spent, failure = record(result, posting, run, resume:, description: posting && descriptions[posting], background:)
        cost += spent
        if score then scores << score
        elsif posting then unweighed << [ posting, failure ] # a result naming no role asked for is nobody's
        end
      end
      by_id.each_value { |posting| unweighed << [ posting, run.stopped ? "the run stopped first (#{run.stopped})" : "no result written" ] }
      weighed(scores, unweighed, cost, run.id, run.stopped)
    end
  end

  # One result through the contract, then kept: its LLM call whatever came of it, and the score. Returns the score (or
  # nil), what it cost, and why there is none.
  def record(result, posting, run, resume:, description:, background: nil)
    errors = Verifier::ResultContract.fit_score_errors(result)
    errors << "not a role asked for" unless posting
    return [ nil, 0.0, "not recorded: #{errors.join('; ')}" ] if errors.any?

    call = record_call(result["llm"], run)
    cost = call ? call.cost_usd.to_f : 0.0
    return [ nil, cost, "the AI could not weigh it (#{result['reason']})" ] unless result["outcome"] == "ok"

    score = posting.fit_scores.create!(
      score: result["score"], level: result["level"].presence, matches: result["matches"], gaps: result["gaps"], why: result["why"],
      dropped_lines: result["dropped_lines"], resume: resume, resume_hash: resume.content_hash, role_description: description,
      description_hash: description.content_hash, written_by: ACTOR, llm_call: call, run_id: run.id,
      **recorded_background(result, background)
    )
    AuditEvent.record!(actor: ACTOR, action: "create", target: score, model_version: call&.model,
                       reasoning: "Weighed: #{said(score)}.", changes_made: facts(score).transform_values { |value| [ nil, value ] })
    [ score, cost, nil ]
  end

  # A score the operator's own Claude client weighed through MCP (2f step 3), saved as `actor` under the credential of
  # that one call: read against the resume version the client saw and the role's newest description, its matches'
  # lines resolved to the resume's own. Returns the score and what was saved, in words.
  #
  # Since 4c the score is the ATS fit, and `background` may carry the Background fit, read with the background version
  # the client saw: { version:, score:, why:, covered: [{ asks:, lines:, address_in:, note: }], preferences: [{ preference:,
  # verdict:, why:, lines: }] }, its lines (B4, or 4) resolved to the background's own.
  def save!(posting, score:, why:, resume_version:, level: nil, matches: [], gaps: [], reported_model: nil, actor: "agent:assistant",
            background: nil)
    raise ArgumentError, "a score is a whole number from 0 to 100" unless score.is_a?(Integer) && score.between?(0, 100)
    raise ArgumentError, "say why, in a sentence" if why.to_s.strip.empty?

    resume = WrittenFrom.resume!(resume_version, reread: "the roles to weigh")
    description = posting.role_descriptions.newest_first.first or
      raise ArgumentError, "#{posting.role_title}'s description isn't read yet: read_descriptions reads it, free"
    matches, dropped = WrittenFrom.with_lines(resume, matches, "point")
    saved = posting.fit_scores.create!(
      score: score, level: level.to_s.strip.presence, matches: matches, gaps: WrittenFrom.gaps(gaps), why: why.to_s.strip,
      dropped_lines: dropped, resume: resume, resume_hash: resume.content_hash, role_description: description,
      description_hash: description.content_hash, written_by: actor, reported_model: WrittenFrom.reported(reported_model),
      run_id: "mcp:#{Authority.credential&.id}", **background_reading(background)
    )
    AuditEvent.record!(actor: actor, action: "create", target: saved, reasoning: "Saved through MCP: #{said(saved)}.",
                       changes_made: facts(saved).transform_values { |value| [ nil, value ] })
    [ saved, "#{said(saved)}." ]
  end

  # The Background fit the fit scorer returned (4c), read against the background it was given: none without one.
  def recorded_background(result, background)
    return {} unless background && result["background_score"]

    { background_score: result["background_score"], background_why: result["background_why"], covered: result["covered"],
      preferences: result["preferences"], background_dropped_lines: result["background_dropped_lines"].to_i,
      background: background, background_hash: background.content_hash }
  end

  # The Background fit's attributes (4c), from what the client gives: none when it gives none.
  def background_reading(given)
    given = WrittenFrom.plain(given)
    return {} if given.values.all?(&:blank?)

    score = given["score"]
    raise ArgumentError, "a Background fit is a whole number from 0 to 100" unless score.is_a?(Integer) && score.between?(0, 100)
    raise ArgumentError, "say why the Background fit is what it is, in a sentence" if given["why"].to_s.strip.empty?

    background = WrittenFrom.background!(given["version"], reread: "the roles to weigh")
    dropped = 0
    cite = lambda do |numbers|
      lines, missing = background.cite(numbers)
      dropped += missing
      lines
    end
    covered = Array(given["covered"]).filter_map do |item|
      item = WrittenFrom.plain(item)
      next if item["asks"].to_s.strip.empty?

      where = item["address_in"].to_s.strip.presence || "resume"
      raise ArgumentError, "a covered gap is addressed in #{FitScore::ADDRESS_IN.keys.join(', or ')}" unless FitScore::ADDRESS_IN.key?(where)

      { "asks" => item["asks"].to_s.strip, "lines" => cite.call(item["lines"]), "address_in" => where, "note" => item["note"].to_s.strip.presence }.compact
    end
    preferences = Array(given["preferences"]).filter_map do |item|
      item = WrittenFrom.plain(item)
      next if item["preference"].to_s.strip.empty?
      raise ArgumentError, "a preference is a match or a miss" unless FitScore::PREFERENCE_VERDICTS.include?(item["verdict"].to_s.strip)

      { "preference" => item["preference"].to_s.strip, "verdict" => item["verdict"].to_s.strip, "why" => item["why"].to_s.strip.presence,
        "lines" => cite.call(item["lines"]) }.compact
    end
    { background_score: score, background_why: given["why"].to_s.strip, covered: covered, preferences: preferences,
      background_dropped_lines: dropped, background: background, background_hash: background.content_hash }
  end

  def record_call(llm, run)
    return unless llm

    LlmCall.create!(run_id: run.id, purpose: llm["purpose"], model: llm["model"], settings: llm["settings"] || {},
                    prompt_version: llm["prompt_version"], input_tokens: llm["input_tokens"],
                    output_tokens: llm["output_tokens"], cost_usd: llm["cost_usd"], called_at: Time.current)
  end

  def weighed(scores, unweighed, cost, run_id, stopped)
    parts = []
    if scores.any?
      top = scores.map(&:score)
      parts << (scores.one? ? "Weighed: #{said(scores.first)}" :
                "Weighed #{scores.size} roles: #{top.count { |value| value >= 70 }} at 70 or more, scores #{top.min} to #{top.max}")
    end
    parts << "#{WrittenFrom.counted(unweighed.size, 'role')} not weighed" if unweighed.any? && scores.size + unweighed.size > 1
    parts << "Not weighed: #{unweighed.first.last}" if unweighed.any? && scores.size + unweighed.size == 1
    parts << "stopped: #{stopped}" if stopped && scores.any?
    Weighed.new(scores:, unweighed:, cost_usd: cost.round(6), run_id: run_id,
                summary: parts.empty? ? "Nothing to weigh." : "#{parts.join('; ')}.")
  end

  # A score in a few words, its text aside: "72 for Sales Engineer at Acme (2 matches, 1 gap)"; and its Background fit
  # (4c), when read: "; Background fit 81 (2 gaps covered, preferences 3 met, 1 missed)".
  def said(score)
    dropped = WrittenFrom.dropped(score.dropped_lines)
    "#{score.score} for #{score.posting.role_title} at #{score.posting.company.name} " \
      "(#{WrittenFrom.counted(score.matches.size, 'match')}, #{WrittenFrom.counted(score.gaps.size, 'gap')})#{dropped}#{background_said(score)}"
  end

  def background_said(score)
    return "" unless score.background_reading?

    tally = score.preference_tally
    lines = WrittenFrom.counted(score.background_dropped_lines, "background line")
    "; Background fit #{score.background_score} (#{score.covered.size} #{score.covered.one? ? 'gap' : 'gaps'} covered, preferences " \
      "#{tally['match']} met, #{tally['miss']} missed#{"; #{lines} it named #{score.background_dropped_lines == 1 ? "isn't" : "aren't"} in the background, left out" if score.background_dropped_lines.positive?})"
  end

  # A role's scores are deleted with it by the database (review pass R4): each one's destroy event is recorded first, by
  # whoever deletes the role, in the form its creation took.
  def record_removal!(posting, actor:, reasoning:)
    posting.fit_scores.each do |score|
      AuditEvent.record!(actor: actor, action: "destroy", target: score, reasoning: reasoning,
                         changes_made: facts(score).transform_values { |value| [ value, nil ] })
    end
  end

  # What a score's audit events say of it: its score, counts and hashes, never its text.
  def facts(score)
    background = ({ "background_score" => score.background_score, "covered" => score.covered.size, "preferences" => score.preference_tally,
                    "background_hash" => score.background_hash } if score.background_reading?)
    { "score" => score.score, "matches" => score.matches.size, "gaps" => score.gaps.size, "resume_hash" => score.resume_hash,
      "description_hash" => score.description_hash, "written_by" => score.written_by, **background.to_h }
  end

  private_class_method :record, :record_call, :weighed, :facts, :background_reading, :background_said, :recorded_background
end
