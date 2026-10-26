module ProvenanceMcp
  # Finding what a client names (Stage 2d, 2e): a company, an application, or a contact, by an id or by the
  # words a person would use. None matching names the close ones; several matching names them all, with their
  # ids. Lists are sorted here, not by the database, whose collation differs between machines.
  module Lookup
    UUID = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/

    module_function

    # A company by its name, its domain, or a link anywhere on its site (careers.acme.com finds acme.com).
    def company(text)
      text = text.to_s.strip
      raise Refusal, "Name a company: its name, its domain, or a link on its site." if text.empty?

      matches = Company.where("lower(name) = :name OR lower(domain) IN (:domains)", name: text.downcase, domains: domains(text))
                       .to_a.sort_by { |found| [ found.name.downcase, found.name ] }
      return matches.sole if matches.one?
      raise Refusal, "Several companies match #{text.inspect}: #{matches.map(&:name).join(', ')}. Which one?" if matches.any?

      close = Company.matching(text).limit(5).pluck(:name).sort_by { |name| [ name.downcase, name ] }
      raise Refusal, "No company matches #{text.inspect}.#{" Close: #{close.join(', ')}." if close.any?}"
    end

    # The domains a name or a link could stand for: a link's host, and the hosts above it.
    def domains(text)
      host = text.downcase.sub(%r{\A[a-z]+://}, "").split(%r{[/?#]}).first.to_s.delete_prefix("www.")
      labels = host.split(".")
      (0..[ labels.size - 2, 0 ].max).map { |from| labels[from..].join(".") }.uniq
    end

    # An application by its id, or by words from its role, company and place ("acme sales engineer").
    def application(text)
      text = text.to_s.strip
      raise Refusal, "Name an application: its id, or its company and role." if text.empty?

      found = Application.includes(:company, :posting).find_by(id: text) if text.match?(UUID)
      return found if found

      matches = Searchable.narrow(Application.joins(posting: :company), text, %w[postings.role_title companies.name postings.location])
                          .includes(:company, :posting).order(:stage_changed_on, :created_at).to_a
      return matches.sole if matches.one?

      listed = (matches.presence || Application.open.includes(:company, :posting).order(:stage_changed_on, :created_at).to_a)
               .first(20).map { |found_one| "- #{Writing.label(found_one)}: #{found_one.id}" }
      raise Refusal, "#{matches.any? ? "Several applications match #{text.inspect}" : "No application matches #{text.inspect}"}. " \
                     "#{matches.any? ? 'They are' : 'The open ones'}:\n#{listed.join("\n").presence || '(none)'}"
    end

    # One of `company`'s contacts, by its id or its name (case aside).
    def contact(company, text)
      text = text.to_s.strip
      raise Refusal, "Name a contact: their name, or their id." if text.empty?

      found = Contacts.named(company, text)
      return found if found

      known = company.contacts.to_a.map { |contact| "- #{contact.label}: #{contact.id}" }
      raise Refusal, "No contact named #{text.inspect} at #{company.name}. #{known.any? ? "Its contacts:\n#{known.join("\n")}" : 'It has none yet.'}"
    end
  end
end
