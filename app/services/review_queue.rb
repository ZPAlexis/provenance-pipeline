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
module ReviewQueue
  Finding = Data.define(:kind, :subject, :evidence, :key, :proposal)

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

    ApplicationRecord.transaction do
      open.each do |item|
        finding = wanted[[ item.kind, item.subject_type, item.subject_id ]]
        next if finding && finding.key == item.evidence_key

        close!(item, "done", "resolved", actor: actor,
                                         reasoning: finding ? "Resolved: what was seen changed." : "Resolved: no longer asked by the record.")
      end
      wanted.each_value { |finding| raise!(company, finding) }
    end
  end

  def raise!(company, finding)
    items = company.review_items.where(kind: finding.kind, subject: finding.subject)
    return if items.open.exists?(evidence_key: finding.key) || items.where(status: "left", evidence_key: finding.key).exists?

    item = company.review_items.create!(kind: finding.kind, subject: finding.subject, evidence: finding.evidence,
                                        evidence_key: finding.key, proposal: finding.proposal, raised_by: RAISED_BY)
    AuditEvent.record_write!(item, actor: RAISED_BY, reasoning: "Raised for review: #{finding.evidence}")
  end

  def close!(item, status, decision, actor:, reasoning:, note: nil)
    item.update!(status: status, decision: decision, decided_by: actor, decided_at: Time.current, note: note)
    AuditEvent.record_write!(item, actor: actor, reasoning: reasoning)
  end

  # --- What a company's record asks of the operator now ----------------------

  def findings(company)
    [ candidate(company), kind(company), no_page(company), partial_list(company),
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

    seen = latest_reasoning(company, "resolution_failure")
    Finding.new(kind: "no_careers_page", subject: company, key: company.resolution_failure,
                proposal: company.resolution_failure == "blocked" ? "set_page" : "find_again",
                evidence: "No careers page found (#{company.resolution_failure}). #{seen}".strip)
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
