# Moves a posting to the company that is really hiring: for a posting sourced
# through an aggregator or a recruiter, whose research found the real employer.
#
# When the posting's own research is where its company's careers page came
# from, that page is the real employer's too, so it moves with the posting: set
# on the employer if it has none, cleared from the company it was wrongly on.
# Every write is audited under the actor who decided, in one transaction.
class PostingReassignment
  def self.call(posting, name:, domain:, actor:, reasoning:)
    new(posting, name: name, domain: domain, actor: actor, reasoning: reasoning).call
  end

  def initialize(posting, name:, domain:, actor:, reasoning:)
    @posting = posting
    @name = name
    @domain = domain
    @actor = actor
    @reasoning = reasoning
  end

  # Returns the company the posting now belongs to.
  def call
    from = @posting.company
    raise ArgumentError, "reasoning is required: say why the posting belongs elsewhere" if @reasoning.blank?

    ApplicationRecord.transaction do
      to = Company.find_or_initialize_for(name: @name, domain: @domain)
      raise ArgumentError, "#{@posting.role_title} already belongs to #{to.name}" if to == from

      carried = carried_page(from)
      to.careers_page_url ||= carried if carried
      save_audited(to, "#{to.new_record? ? 'Created' : 'Updated'} as the real employer behind a posting sourced through #{from.name}.")

      @posting.update!(company: to)
      AuditEvent.record_write!(@posting, actor: @actor, reasoning: "Moved from #{from.name} to #{to.name}. #{@reasoning}")

      if carried
        from.careers_page_url = nil
        save_audited(from, "Its careers page was #{to.name}'s, found by research on a posting now moved there.")
      end
      to
    end
  end

  private

  # The company's careers page, when this posting's research is where it came from.
  def carried_page(company)
    page = @posting.enrichment["careers_page_url"]
    page if page.present? && page == company.careers_page_url
  end

  def save_audited(company, note)
    return unless company.changed?

    company.save!
    AuditEvent.record_write!(company, actor: @actor, reasoning: "#{note} #{@reasoning}")
  end
end
