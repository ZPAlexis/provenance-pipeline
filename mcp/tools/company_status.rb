module ProvenanceMcp
  module Tools
    # One company as the record has it now: its careers page and how it was found, its roles by answer, when its
    # page was last checked, and its applications. The side track's first tool (M4), hardened in 2d step 1: a
    # company is found by its name, its domain, or a link on its site, and counts follow the app's own rules
    # (dismissed roles apart, aggregators never watched).
    class CompanyStatus < ReadTool
      tool_name "get_company_status"
      title "A company's status"
      description "One company as the record has it now: its careers page and how it was found, its roles by " \
                  "whether its own page still lists them (dismissed roles counted apart), when the page was last " \
                  "checked, and its applications. Finds the company by its name, its domain, or a link on its site; " \
                  "says so when none matches or several do."
      input_schema(
        properties: { company: { type: "string", description: "Its name, its domain (acme.com), or a link on its site" } },
        required: [ "company" ]
      )

      ANSWERS = %w[verified_live not_found inaccessible pending].freeze

      class << self
        def answer(company:)
          found = find(company)
          ProvenanceMcp.text(heading(found), "Careers page: #{page(found)}", roles(found), checked(found), applications(found))
        end

        private

        def find(text)
          text = text.to_s.strip
          raise Refusal, "Name a company: its name, its domain, or a link on its site." if text.empty?

          # Sorted here, not by the database: its collation differs between machines ("acme" before "Acme" on one, after on another).
          matches = Company.where("lower(name) = :name OR lower(domain) IN (:domains)", name: text.downcase, domains: domains(text))
                           .to_a.sort_by { |found| [ found.name.downcase, found.name ] }
          return matches.sole if matches.one?
          raise Refusal, "Several companies match #{text.inspect}: #{matches.map(&:name).join(', ')}. Which one?" if matches.any?

          close = Company.matching(text).order(:name).limit(5).pluck(:name)
          raise Refusal, "No company matches #{text.inspect}.#{" Close: #{close.join(', ')}." if close.any?}"
        end

        # The domains a name or a link could stand for: a link's host, and the hosts above it (careers.acme.com is acme.com).
        def domains(text)
          host = text.downcase.sub(%r{\A[a-z]+://}, "").split(%r{[/?#]}).first.to_s.delete_prefix("www.")
          labels = host.split(".")
          (0..[ labels.size - 2, 0 ].max).map { |from| labels[from..].join(".") }.uniq
        end

        def heading(company)
          kind = { "recruiter" => "a recruiter (its roles are its clients')", "aggregator" => "an aggregator (other employers' roles: never watched)" }
          "#{company.name}#{" (#{company.domain})" if company.domain}#{", #{kind[company.kind]}" if kind[company.kind]}"
        end

        def page(company)
          case company.resolution_status
          when "resolved"
            how = [ company.resolution_method&.tr('_', ' '), ("#{company.resolution_confidence} confidence" if company.resolution_confidence) ].compact
            board = ", read through its free #{company.board_vendor.capitalize} board" if company.board_in_use
            "#{company.kind == 'aggregator' ? 'on record, not watched' : 'watched'}: #{company.careers_page_url}" \
              "#{" (found by #{how.join(', ')})" if how.any?}#{board}"
          when "candidate" then "a candidate found at low confidence, waiting for the operator to confirm: #{company.resolution_candidate_url}"
          when "failed" then "none found (#{company.resolution_failure&.tr('_', ' ') || 'no reason recorded'})"
          else "not looked for yet"
          end
        end

        def roles(company)
          by_tracking = company.postings.group(:tracking).count
          in_play = company.postings.not_dismissed.group(:verification_state).count
          answers = ANSWERS.filter_map { |state| "#{Posting::ANSWER_LABELS.fetch(state).downcase} #{in_play[state]}" if in_play[state] }
          [ "Roles in play: #{in_play.values.sum} (tracked #{by_tracking.fetch('tracked', 0)}, suggested #{by_tracking.fetch('suggested', 0)})" \
            "#{": #{answers.join(', ')}" if answers.any?}",
            "Dismissed roles: #{by_tracking.fetch('dismissed', 0)} (never checked or suggested again)" ]
        end

        def checked(company)
          last = company.page_checks.where(purpose: "verification").maximum(:checked_at)
          return "Careers page last checked: never" unless last

          days = ((Time.current - last) / 1.day).floor
          "Careers page last checked: #{last.utc.strftime('%Y-%m-%d %H:%M')} UTC (#{days.zero? ? 'today' : "#{days} #{'day'.pluralize(days)} ago"})"
        end

        def applications(company)
          stages = company.applications.group(:stage).count
          return "Applications: none" if stages.empty?

          "Applications: #{stages.values.sum} (#{stages.sort_by { |stage, _| Application::STAGES.index(stage) }
                                                         .map { |stage, count| "#{Application.stage_label(stage).downcase} #{count}" }.join(', ')})"
        end
      end
    end
  end
end
