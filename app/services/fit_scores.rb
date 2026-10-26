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

  # A role's newest score as the pages show it: with what has changed since it was weighed (empty when nothing has).
  Shown = Data.define(:score, :stale) do
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
    resume = SearchProfile.current&.resumes&.newest_first&.first
    descriptions = RoleDescription.where(posting: postings).select(:id, :posting_id, :content_hash, :first_read_at, :created_at)
                                  .newest_first.group_by(&:posting_id) # their hashes, not their text
    newest(postings).transform_values { |score| Shown.new(score:, stale: score.stale_for(resume, descriptions[score.posting_id]&.first)) }
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

  def target(posting, resume:, description:, profile:)
    { id: posting.id, label: "#{posting.company.name} / #{posting.role_title}", role_title: posting.role_title,
      company: posting.company.name, location: posting.location, description: description.text, resume: resume.text,
      titles: profile.titles }
  end

  # Weighs each of `postings` against the newest resume as the fit scorer, from its newest description; a role with
  # no description on record is left unweighed, and says so.
  def weigh!(postings, worker: Verifier::Worker.new(run_dir: Verifier::Worker.dir_for("fit")), issued_by: AuditEvent::OPERATOR)
    postings = Array(postings)
    why = refusal(postings)
    raise ArgumentError, why if why

    profile = SearchProfile.current
    resume = profile.resumes.newest_first.first
    descriptions = postings.index_with { |posting| posting.role_descriptions.newest_first.first }
    unweighed = postings.reject { |posting| descriptions[posting] }.map { |posting| [ posting, "no description on record" ] }
    ready = postings.select { |posting| descriptions[posting] }
    return weighed([], unweighed, 0.0, nil, nil) if ready.empty?

    purpose = ready.one? ? "fit: #{ready.first.role_title} at #{ready.first.company.name}" : "fit: #{ready.size} roles"
    Authority.run(ACTOR, scopes: SCOPES, purpose: purpose, ttl: ready.one? ? Authority::ONE : Authority::BATCH, issued_by: issued_by) do
      run = begin
        worker.run(ready.map { |posting| target(posting, resume:, description: descriptions[posting], profile:) }, command: "fit")
      ensure
        FileUtils.rm_f(worker.run_dir.join("targets.json")) # it holds the whole resume
      end
      by_id = ready.index_by(&:id)
      scores, cost = [], 0.0
      run.results.each do |result|
        posting = by_id.delete(result["target_id"]) if result.is_a?(Hash)
        score, spent, failure = record(result, posting, run, resume:, description: posting && descriptions[posting])
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
  def record(result, posting, run, resume:, description:)
    errors = Verifier::ResultContract.fit_score_errors(result)
    errors << "not a role asked for" unless posting
    return [ nil, 0.0, "not recorded: #{errors.join('; ')}" ] if errors.any?

    call = record_call(result["llm"], run)
    cost = call ? call.cost_usd.to_f : 0.0
    return [ nil, cost, "the AI could not weigh it (#{result['reason']})" ] unless result["outcome"] == "ok"

    score = posting.fit_scores.create!(
      score: result["score"], level: result["level"].presence, matches: result["matches"], gaps: result["gaps"], why: result["why"],
      dropped_lines: result["dropped_lines"], resume: resume, resume_hash: resume.content_hash, role_description: description,
      description_hash: description.content_hash, written_by: ACTOR, llm_call: call, run_id: run.id
    )
    AuditEvent.record!(actor: ACTOR, action: "create", target: score, model_version: call&.model,
                       reasoning: "Weighed: #{said(score)}.", changes_made: facts(score).transform_values { |value| [ nil, value ] })
    [ score, cost, nil ]
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

  # A score in a few words, its text aside: "72 for Sales Engineer at Acme (2 matches, 1 gap)".
  def said(score)
    dropped = WrittenFrom.dropped(score.dropped_lines)
    "#{score.score} for #{score.posting.role_title} at #{score.posting.company.name} " \
      "(#{WrittenFrom.counted(score.matches.size, 'match')}, #{WrittenFrom.counted(score.gaps.size, 'gap')})#{dropped}"
  end

  # What a score's audit events say of it: its score, counts and hashes, never its text.
  def facts(score)
    { "score" => score.score, "matches" => score.matches.size, "gaps" => score.gaps.size, "resume_hash" => score.resume_hash,
      "description_hash" => score.description_hash, "written_by" => score.written_by }
  end

  private_class_method :record, :record_call, :weighed, :facts
end
