# A record's history as its page shows it (4e): every change to it and to what was saved under it, the AI assistant's
# included, from the audit log alone. A role: its fit scores. An application: its activities and contacts (by the
# application's id they record, so a deleted one shows too), its drafts and its resume reviews. A company: its reviews
# and its contacts (by the company's id they record). Since 4e step 9, what each page watches for the AI assistant's
# changes while it is open: its history, and the other records its header shows.
module RecordHistory
  ASSISTANT = "agent:assistant".freeze

  # What a page's record is called in the address it polls.
  KINDS = { "role" => "Posting", "application" => "Application", "company" => "Company" }.freeze

  # How a change the assistant made is named in the page's banner: what it saved, by the kind of record.
  NAMED = { "FitScore" => "a fit score", "CompanyReview" => "a company review", "ResumeReview" => "a resume review",
            "Draft" => "a draft", "Activity" => "an activity", "Contact" => "a contact", "ApplicationContact" => "a linked contact",
            "Posting" => "a role", "Company" => "a company", "Application" => "the application" }.freeze

  module_function

  # The history a page's History tab shows, unordered.
  def for(record)
    case record
    when Posting then events(record).or(of("FitScore", record.fit_scores))
    when Application
      under = AuditEvent.where(target_type: %w[Activity ApplicationContact])
                        .where("jsonb_exists(changes_made -> 'application_id', :id)", id: record.id)
      events(record).or(under).or(of("Draft", record.drafts)).or(of("ResumeReview", record.resume_reviews))
    when Company
      contacts = AuditEvent.where(target_type: "Contact").where("jsonb_exists(changes_made -> 'company_id', :id)", id: record.id)
      events(record).or(contacts).or(of("Contact", record.contacts)).or(of("CompanyReview", record.company_reviews))
    else raise ArgumentError, "no history page for #{record.class.name}"
    end
  end

  # What a page watches while it is open: its history, and what its header shows besides (a role's company review and
  # application; an application's role and its fit scores, and its company's reviews; a company's roles and their fit
  # scores).
  def watched(record)
    case record
    when Posting
      self.for(record).or(of("CompanyReview", record.company.company_reviews)).or(of("Application", Application.where(posting_id: record.id)))
    when Application
      self.for(record).or(events(record.posting)).or(of("FitScore", record.posting.fit_scores))
          .or(of("CompanyReview", record.company.company_reviews))
    when Company
      self.for(record).or(of("Posting", record.postings)).or(of("FitScore", FitScore.where(posting_id: record.postings.select(:id))))
    else raise ArgumentError, "no history page for #{record.class.name}"
    end
  end

  # The AI assistant's changes to what a page shows since `since` (it was opened): none refused.
  def assistant_changes(record, since:)
    watched(record).where(actor: ASSISTANT).where.not(action: "denied").where(occurred_at: since..)
  end

  # Those changes in a sentence for the page's banner; nil when there are none. The page's own record is "this role"
  # (or company, or application), said first; the rest are counted by kind, in the order they first happened:
  # "this role and 2 fit scores". Always in that order, whatever order the changes came in.
  def said(changes, record)
    return if changes.empty?

    ordered = changes.sort_by { |event| [ event.occurred_at, event.id ] }
    parts = ordered.group_by { |event| event.target_type == record.class.name && event.target_id == record.id ? :own : event.target_type }
                   .sort_by { |kind, _| kind == :own ? 0 : 1 }
                   .map do |kind, events|
      next "this #{KINDS.key(record.class.name)}" if kind == :own

      named = NAMED.fetch(kind, "a #{kind.underscore.humanize(capitalize: false)}")
      events.size == 1 ? named : "#{events.size} #{named.split(' ', 2).last.pluralize}"
    end
    "Your AI assistant changed this page since you opened it: #{parts.to_sentence}."
  end

  def events(record) = AuditEvent.where(target: record)

  def of(kind, records) = AuditEvent.where(target_type: kind, target_id: records.select(:id))
end
