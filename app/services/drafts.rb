# Cover letters and outreach notes (Stage 2c), for an application. The drafter
# writes one with the worker's `draft` (one LLM call, Opus 5.5) from what is on
# record alone: the newest resume, the role's newest description, the search
# profile, and the application's notes. It writes under a credential for its run
# holding drafts:write alone, which allows a new draft and the call that wrote it,
# nothing more. Editing and approving are the operator's. Nothing is ever sent.
#
# Each draft is audited by its size and hash, never its text, as the resume is:
# a draft is the resume paraphrased. The run's targets file holds the whole
# resume, so it is removed when the run ends.
module Drafts
  ACTOR = "agent:drafter".freeze
  SCOPES = %w[drafts:write].freeze
  MAX_GUIDANCE = 500
  MAX_LANGUAGE = 40
  # What a draft costs before there is one on the record: Opus 5.5 at medium effort,
  # about 3k tokens in and 2-4k out (its thinking included).
  FIRST_ESTIMATE = 0.07

  # What one drafting run did, answering a check run as a check's outcome does (CheckNowJob).
  Written = Data.define(:application, :draft, :summary, :cost_usd, :run_id) do
    def finished? = !draft.nil?

    def answer = draft ? "drafted" : "not drafted"

    def tally = {}
  end

  module_function

  # What drafting `application` still needs, in words; empty when it can be drafted.
  def missing(application)
    [ ("a resume, saved on the Profile page" unless SearchProfile.current&.resumes&.exists?),
      ("the role's description, read on its page" unless application.posting.role_descriptions.exists?) ].compact
  end

  # What a draft costs, on the record; a cautious guess before the first one.
  def estimate = LlmCall.where(purpose: "draft").average(:cost_usd)&.to_f || FIRST_ESTIMATE

  def target(application, kind:, language:, guidance:, resume:, description:, profile:)
    role = application.posting
    { id: application.id, kind: kind, label: "#{application.company.name} / #{role.role_title}", role_title: role.role_title,
      company: application.company.name, location: role.location, description: description.text, resume: resume.text,
      titles: profile.titles, places: profile.places, work_modes: profile.work_modes, notes: application.notes.presence,
      guidance: guidance, language: language }
  end

  # Writes a draft of `kind` for `application` as the drafter, in `language` (nil: its description's).
  def write!(application, kind:, language: nil, guidance: nil, worker: Verifier::Worker.new(run_dir: Verifier::Worker.dir_for("draft")),
             issued_by: AuditEvent::OPERATOR)
    language, guidance = language.to_s.strip.presence, guidance.to_s.strip.presence
    check_request!(application, kind, language, guidance)
    profile = SearchProfile.current
    resume = profile.resumes.newest_first.first
    description = application.posting.role_descriptions.newest_first.first

    Authority.run(ACTOR, scopes: SCOPES, purpose: "draft: #{Draft.label(kind).downcase} for #{application.posting.role_title} " \
                                                  "at #{application.company.name}", issued_by: issued_by) do
      run = begin
        worker.run([ target(application, kind:, language:, guidance:, resume:, description:, profile:) ], command: "draft")
      ensure
        FileUtils.rm_f(worker.run_dir.join("targets.json")) # it holds the whole resume
      end
      record(application, run, kind:, language:, guidance:, resume:, description:)
    end
  end

  def check_request!(application, kind, language, guidance)
    raise ArgumentError, "unknown kind of draft #{kind.inspect}" unless Draft::KINDS.include?(kind)
    raise ArgumentError, "a language is named in a few words, not #{language.size} characters" if language && language.size > MAX_LANGUAGE
    raise ArgumentError, "what to stress fits in #{MAX_GUIDANCE} characters" if guidance && guidance.size > MAX_GUIDANCE

    needs = missing(application)
    raise ArgumentError, "drafting needs #{needs.to_sentence} first" if needs.any?
  end

  # The run's one result through the contract, then kept: its LLM call whatever came of it (billed all the same), and the draft.
  def record(application, run, kind:, language:, guidance:, resume:, description:)
    result = run.results.first
    return Written.new(application:, draft: nil, cost_usd: 0.0, run_id: run.id, summary: "Stopped before it was written: " \
                                                                                          "#{run.stopped || 'no result written'}.") unless result

    errors = Verifier::ResultContract.draft_errors(result)
    errors << "not the application asked for" unless result["target_id"] == application.id
    return Written.new(application:, draft: nil, cost_usd: 0.0, run_id: run.id, summary: "Not recorded: #{errors.join('; ')}.") if errors.any?

    call = record_call(result["llm"], run)
    cost = call ? call.cost_usd.to_f : 0.0
    unless result["outcome"] == "ok"
      return Written.new(application:, draft: nil, cost_usd: cost, run_id: run.id, summary: "The AI could not write it (#{result['reason']}).")
    end

    draft = application.drafts.create!(
      kind: kind, language: result["language"], asked_language: language, guidance: guidance,
      subject: result["subject"], body: result["body"], written_subject: result["subject"], written_body: result["body"],
      drew_on: result["drew_on"], gaps: result["gaps"], notes: result["notes"], dropped_lines: result["dropped_lines"],
      resume: resume, resume_hash: resume.content_hash, role_description: description, description_hash: description.content_hash,
      llm_call: call, run_id: run.id
    )
    gaps = draft.gaps.empty? ? "no gaps" : "#{counted(draft.gaps.size, 'gap')} flagged"
    dropped = "; #{counted(draft.dropped_lines, 'line')} it named aren't in the resume, left out" if draft.dropped_lines.positive?
    summary = "#{draft.label} in #{draft.language}: #{counted(draft.words, 'word')}, drawing on " \
              "#{counted(draft.drew_on.size, 'line')} of the resume, #{gaps}#{dropped}."
    AuditEvent.record!(actor: ACTOR, action: "create", target: draft, model_version: call&.model, reasoning: "Drafted: #{summary}",
                       changes_made: facts(draft).transform_values { |value| [ nil, value ] })
    Written.new(application:, draft:, cost_usd: cost, run_id: run.id, summary: summary)
  end

  def record_call(llm, run)
    return unless llm

    LlmCall.create!(run_id: run.id, purpose: llm["purpose"], model: llm["model"], settings: llm["settings"] || {},
                    prompt_version: llm["prompt_version"], input_tokens: llm["input_tokens"],
                    output_tokens: llm["output_tokens"], cost_usd: llm["cost_usd"], called_at: Time.current)
  end

  # The operator's edit of a draft's text; nil when it says the same. An approved draft returns to a draft.
  def edit!(draft, body:, subject: draft.subject, actor: AuditEvent::OPERATOR)
    body = body.to_s.gsub("\r\n", "\n").strip
    subject = draft.kind == "outreach" ? subject.to_s.strip.presence : nil
    raise ArgumentError, "a draft needs its text: delete it instead" if body.empty?
    return if body == draft.body && subject == draft.subject

    before = facts(draft)
    ApplicationRecord.transaction do
      draft.update!(body: body, subject: subject, edited_at: Time.current, status: "draft", approved_at: nil)
      reopened = " It was approved: it is a draft again." if before["status"] == "approved"
      AuditEvent.record!(actor: actor, action: "update", target: draft, changes_made: changed(before, facts(draft)),
                         reasoning: "#{draft.label} edited on its application's page: #{counted(draft.words, 'word')}.#{reopened}")
      draft
    end
  end

  # The operator's approval: the text they will send themselves.
  def approve!(draft, actor: AuditEvent::OPERATOR)
    raise ArgumentError, "it is approved already" if draft.approved?

    before = facts(draft)
    ApplicationRecord.transaction do
      draft.update!(status: "approved", approved_at: Time.current)
      AuditEvent.record!(actor: actor, action: "update", target: draft, changes_made: changed(before, facts(draft)),
                         reasoning: "#{draft.label} approved on its application's page: #{counted(draft.words, 'word')}. Nothing is sent.")
      draft
    end
  end

  # The operator's deletion; its audit record names its size and hash, as every one of its events does.
  def delete!(draft, actor: AuditEvent::OPERATOR)
    ApplicationRecord.transaction do
      AuditEvent.record!(actor: actor, action: "destroy", target: draft, changes_made: facts(draft).transform_values { |value| [ value, nil ] },
                         reasoning: "#{draft.label} deleted on its application's page.")
      draft.destroy!
    end
  end

  # What a draft's audit events say of it: its facts, never its text.
  def facts(draft)
    { "kind" => draft.kind, "status" => draft.status, "language" => draft.language, "words" => draft.words,
      "content_hash" => draft.content_hash, "resume_hash" => draft.resume_hash, "description_hash" => draft.description_hash }
  end

  def changed(before, after) = after.filter_map { |key, value| [ key, [ before[key], value ] ] unless before[key] == value }.to_h

  def counted(count, what) = "#{count} #{what.pluralize(count)}"

  private_class_method :check_request!, :record, :record_call, :facts, :changed, :counted
end
