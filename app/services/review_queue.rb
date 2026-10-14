# The operator's review queue (1.5e): what an agent saw that needs a person's
# judgment, one item per question about one company or role, each with its
# evidence, a proposed action, and who raised it.
#
# The questions are worked out from the record (`findings`), so the queue never
# disagrees with it: `sync!` raises an item for each finding with none open,
# and closes an open item whose finding is gone (its evidence resolved). Every
# write is audited. An item the operator left is raised again only when the
# evidence changes: a finding with the same evidence_key stays left.
#
# Called after every write that can change what a company's record asks (the
# verifier's reads, the operator's decisions, the suggester's withdrawals);
# `bin/rails review:sync` reconciles every company at once.
#
# This bookkeeping is written by the queue itself, under a grant fixed in code
# (Authority::SYSTEM, 1.3): it raises, restates, and closes what resolved, and
# never decides. Each item still names whose evidence raised it.
module ReviewQueue
  Finding = Data.define(:kind, :subject, :evidence, :key, :proposal)

  ACTOR = "system:review_queue".freeze
  # Who saw what each kind is about: every finding so far comes from the verifier's reads.
  RAISED_BY = Verifier::Ingest::ACTOR
  # Failures a person can do something about; "rejected" was their own call, "anonymised" names no company.
  FINDABLE = %w[not_found blocked inaccessible].freeze

  module_function

  # Brings a company's open items in line with what its record asks now.
  # `actor` is who made the write that led here: an item it settles is decided by them.
  def sync!(company, actor: RAISED_BY)
    wanted = findings(company).index_by { |finding| [ finding.kind, finding.subject.class.name, finding.subject.id ] }
    open = company.review_items.open.to_a

    Authority.as_system(ACTOR) { keep_in_step!(company, wanted, open, actor) }
  end

  def keep_in_step!(company, wanted, open, actor)
    ApplicationRecord.transaction do
      open.each do |item|
        finding = wanted[[ item.kind, item.subject_type, item.subject_id ]]
        next restate!(item, finding) if finding && finding.key == item.evidence_key

        close!(item, "done", "resolved", actor: actor, audit_as: ACTOR,
                                         reasoning: finding ? "Resolved: what was seen changed." : "Resolved: no longer asked by the record.")
      end
      wanted.each_value { |finding| raise!(company, finding) }
    end
  end

  DECISIONS = %w[confirm reject set_page set_kind find_again check_again still_listed no_longer_listed undo leave].freeze
  DONE = {
    "confirm" => "Confirmed: its careers page is watched. Check it now to read its roles.",
    "reject" => "Rejected: set the right page by hand if you know it.",
    "set_page" => "Set: its careers page is watched. Check it now to read its roles.",
    "set_kind" => "Its kind is set.",
    "still_listed" => "Recorded: still listed, as you saw it.",
    "no_longer_listed" => "Recorded: no longer listed, as you saw it.",
    "undo" => "The verdict is undone.",
    "leave" => "Left as is: it comes back only if what was seen changes."
  }.freeze

  # Carries out the operator's decision on an open item, through the service that
  # makes that write; returns what was done, in a sentence. Shared by the Review
  # page and review:decide. `check` runs a check asked for from the queue (in the
  # background from the page, in the foreground from the command line): the item
  # stays open, and closes if the check settles it.
  def act!(item, decision, check:, note: nil, url: nil, kind: nil)
    raise ArgumentError, "that item is already decided." unless item.status == "open"
    raise ArgumentError, "unknown decision #{decision.inspect}: one of #{DECISIONS.join(', ')}" unless DECISIONS.include?(decision)

    company, role, note = item.company, item.subject, note.to_s.strip.presence
    if %w[find_again check_again].include?(decision)
      record = decision == "find_again" ? company : role or raise ArgumentError, "the role asked about is no longer on record"
      why = Verifier::CheckNow.refusal(record) and raise ArgumentError, why
      said = check.call(record)
      return said.is_a?(String) ? said : "Checking it now, in the background: the item shows how it goes, and closes if the check settles it."
    end

    decide!(item, decision, note: note) do
      case decision
      when "confirm" then Verifier::Candidates.confirm!(company)
      when "reject" then Verifier::Candidates.reject!(company)
      when "set_page" then Verifier::Candidates.set_page!(company, url.to_s.strip, reasoning: note)
      when "set_kind" then Verifier::Candidates.set_kind!(company, kind.to_s, reasoning: note)
      when "still_listed", "no_longer_listed"
        Verifier::HandCheck.record!(role, verdict: decision == "still_listed" ? "verified_live" : "not_found", note: note)
      when "undo" then Verifier::HandCheck.undo_verdict!(role, reasoning: note)
      end
    end
    DONE.fetch(decision)
  end

  # The operator's decision on an item, carried out by the block through the
  # services every such write goes through. The item closes with the decision in
  # the same transaction: a write that fails leaves it open. "leave" closes it as
  # left, and it comes back only when the evidence changes.
  def decide!(item, decision, note: nil, actor: AuditEvent::OPERATOR)
    left = decision == "leave"
    raise ArgumentError, "say why you leave it as is: your note goes on the record" if left && note.blank?

    ApplicationRecord.transaction do
      close!(item, left ? "left" : "done", decision, actor: actor, note: note,
                                                     reasoning: left ? "Left as is by hand: #{note}" : "Decided by hand: #{decision.humanize.downcase}.#{" #{note}" if note}")
      yield if block_given?
    end
  end

  def raise!(company, finding)
    items = company.review_items.where(kind: finding.kind, subject: finding.subject)
    return if items.open.exists?(evidence_key: finding.key) || items.where(status: "left", evidence_key: finding.key).exists?

    item = company.review_items.create!(kind: finding.kind, subject: finding.subject, evidence: finding.evidence,
                                        evidence_key: finding.key, proposal: finding.proposal, raised_by: RAISED_BY)
    AuditEvent.record_write!(item, actor: ACTOR, reasoning: "Raised for review: #{finding.evidence}")
  end

  # The same evidence, worded as the record words it now.
  def restate!(item, finding)
    return if item.evidence == finding.evidence

    item.update!(evidence: finding.evidence)
    AuditEvent.record_write!(item, actor: ACTOR, reasoning: "Restated what was seen.")
  end

  # Closes an item as `actor`'s; audited as the queue when its bookkeeping closes it (`audit_as`).
  def close!(item, status, decision, actor:, reasoning:, note: nil, audit_as: actor)
    item.update!(status: status, decision: decision, decided_by: actor, decided_at: Time.current, note: note)
    AuditEvent.record_write!(item, actor: audit_as, reasoning: reasoning)
  end

  # --- What a company's record asks of the operator now ----------------------

  def findings(company)
    [ candidate(company), kind(company), no_page(company), partial_list(company), page_changed(company),
      *company.postings.where.not(tracking: "dismissed").flat_map { |posting| [ suspect(posting), unconfirmed(posting) ] } ].compact
  end

  def candidate(company)
    return unless company.resolution_status == "candidate"

    seen = latest_reasoning(company, "resolution_candidate_url")
    Finding.new(kind: "careers_page_candidate", subject: company, key: company.resolution_candidate_url, proposal: "confirm",
                evidence: "Found by #{company.resolution_method} at low confidence: #{company.resolution_candidate_url}. #{seen}".strip)
  end

  def kind(company)
    return unless company.kind_suggestion && company.kind.nil?

    Finding.new(kind: "company_kind", subject: company, key: company.kind_suggestion,
                proposal: "set_kind:#{company.kind_suggestion}",
                evidence: "Its pages look like a #{company.kind_suggestion}'s. #{company.kind_evidence}".strip)
  end

  def no_page(company)
    return unless company.resolution_status == "failed" && FINDABLE.include?(company.resolution_failure)
    return if Verifier::Resolution.anonymised?(company)

    Finding.new(kind: "no_careers_page", subject: company, key: company.resolution_failure,
                proposal: company.resolution_failure == "blocked" ? "set_page" : "find_again",
                evidence: latest_reasoning(company, "resolution_failure") || "No careers page found (#{company.resolution_failure}).")
  end

  # A watched list read only in part: a role missing from it is never marked no longer listed.
  # Asked only while roles are in play there; raised again only for another page.
  def partial_list(company)
    return unless company.resolution_status == "resolved" && company.kind != "aggregator"
    return unless company.postings.where.not(tracking: "dismissed").exists?

    check, listings = Verifier::Targets.latest_list(company)
    return unless check

    pages = company.page_checks.where(run_id: check.run_id, purpose: "verification")
    total = pages.filter_map(&:stated_total).max
    # As the worker judges a list (pipeline._whole_list): a stated total read in full settles it, whatever a page's flag says.
    return unless pages.any?(&:listings_incomplete) && !(total && listings.size >= total)

    Finding.new(kind: "partial_list", subject: company, key: company.careers_page_url, proposal: "set_page",
                evidence: "Read #{listings.size}#{" of #{total}" if total} roles at #{company.careers_page_url} " \
                          "on #{check.checked_at.to_date}: the page shows only part of its list, so a role missing from it " \
                          "is never marked no longer listed.")
  end

  # A watched list that changed a lot between two whole reads (1.4): is the page still this company's list?
  # Asked while roles are in play there; raised again only for a later change.
  def page_changed(company)
    return unless company.resolution_status == "resolved" && company.kind != "aggregator"
    return unless company.postings.where.not(tracking: "dismissed").exists?

    change = Verifier::ListChange.latest(company) or return
    Finding.new(kind: "page_changed", subject: company, key: change.after.id, proposal: "review_page",
                evidence: "#{change.summary}. A list that changes this much is often a different page now (a redirect, " \
                          "a redesign, a parent company's list), and every verdict there rests on it.")
  end

  # A verdict reached on weak evidence: "no longer listed" from a read that saw no roles at all,
  # or "still listed" on the AI's judgment alone. Never one the operator gave themselves.
  def suspect(posting)
    return if by_hand?(posting)

    if posting.suspect_negative?
      Finding.new(kind: "suspect_verdict", subject: posting, key: "not_found:empty_read", proposal: "hand_check",
                  evidence: "Marked no longer listed from a read that saw no roles at all: more likely a page that " \
                            "did not load than a closed role.")
    elsif posting.verification_state == "verified_live" && (match = latest_match(posting)) && match["method"] == "llm"
      Finding.new(kind: "suspect_verdict", subject: posting, key: "verified_live:llm", proposal: "hand_check",
                  evidence: "Marked still listed on the AI's judgment alone. #{match['reasoning']}")
    end
  end

  def unconfirmed(posting)
    return unless posting.verification_state == "inaccessible" && !by_hand?(posting)

    Finding.new(kind: "unconfirmed_role", subject: posting, key: "inaccessible", proposal: "check_again",
                evidence: "Couldn't confirm: #{latest_reasoning(posting, 'verification_state') || 'its page refused or failed us.'}")
  end

  # --- Evidence helpers -------------------------------------------------------

  # The reasoning of the latest audited change to `attribute` on a record: why it is as it is.
  def latest_reasoning(record, attribute)
    record.audit_events.where("changes_made ? :attribute", attribute: attribute).order(:occurred_at).last&.reasoning
  end

  # Whether the role's current verdict is the operator's own: its latest audited check time is theirs.
  def by_hand?(posting)
    posting.audit_events.where("changes_made ? 'last_checked_at'").order(:occurred_at).last&.actor == AuditEvent::OPERATOR
  end

  # How the role was last matched, from the latest verification that said anything about it.
  def latest_match(posting)
    check = posting.company.page_checks.where(purpose: "verification").where("matches @> ?", [ { posting_id: posting.id } ].to_json)
                   .order(checked_at: :desc).first
    check&.matches&.find { |match| match["posting_id"] == posting.id }
  end
end
