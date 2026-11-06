module ProvenanceMcp
  module Tools
    # The companies on the watch list as the Companies page lists them (4a step 4, WatchList): tracked, archived or
    # all, narrowed to what needs a look or to words, each with its id, domain, careers page, roles, application and
    # last check, a page at a time. The companies' text is the record's, between markers.
    class ListCompanies < ReadTool
      PAGE = 50
      # The tool's words for the page's tabs and filters: "archived" is stored "dismissed".
      TRACKING = { "tracked" => "tracked", "archived" => "dismissed", "all" => "all" }.freeze
      NEEDS = { "no_careers_page" => "no_page", "page_to_confirm" => "to_confirm", "no_role_tracked" => "none_tracked",
                "none_still_listed" => "none_listed" }.freeze

      tool_name "list_companies"
      title "List the companies"
      description "The companies on the watch list, as the app's Companies page lists them: those the operator tracks " \
                  "(the default), those archived, or all; narrowed, when asked, to what needs a look (no careers page " \
                  "yet, a careers page to confirm, no role tracked, or roles tracked none of which is still listed) or " \
                  "to words in a name, a domain or a place it hires in. Each with its id, domain, careers page, its roles " \
                  "(tracked and suggested, the tracked ones by answer, archived), its application and its last check. " \
                  "#{PAGE} a page, in name order: give offset for the next."
      input_schema(
        properties: {
          tracking: { type: "string", enum: TRACKING.keys, description: "Which companies: tracked (the default), archived, or all" },
          needs: { type: "string", enum: NEEDS.keys, description: "Only those that need this look" },
          find: { type: "string", description: "Words in a company's name, its domain, or a place it hires in" },
          offset: { type: "integer", description: "How many to skip, for the next page" }
        }
      )

      class << self
        def answer(tracking: "tracked", needs: nil, find: nil, offset: 0)
          tab = TRACKING.fetch(tracking.to_s) { raise Refusal, "tracking is one of #{TRACKING.keys.join(', ')}." }
          filter = NEEDS.fetch(needs.to_s) { raise Refusal, "needs is one of #{NEEDS.keys.join(', ')}." } if needs.present?
          found = Company.matching(find.to_s.strip.presence)
          tabs, filters = WatchList.counts(found, tab)
          companies = WatchList.narrow(WatchList.in_tab(found, tab), filter).to_a.sort_by { |company| [ company.name.downcase, company.name ] }
          from = [ offset.to_i, 0 ].max
          page = companies[from, PAGE] || []
          ids = page.map(&:id)
          roles, applications, checked = WatchList.role_counts(ids), WatchList.applications(ids), WatchList.last_checked(ids)
          lines = page.map { |company| line(company, roles, applications[company.id], checked[company.id], tab) }

          ProvenanceMcp.text(summary(tabs, filters, tab, find), shown(companies.size, from, page.size, needs),
                             (Writing.fence("record", lines.join("\n")) if lines.any?))
        end

        private

        def summary(tabs, filters, tab, find)
          counts = TRACKING.map { |word, stored| "#{word} #{tabs.fetch(stored)}" }.join(", ")
          within = WatchList::FILTERS.map { |key, (label, *)| "#{label.downcase} #{filters.fetch(key)}" }.join(", ")
          "Companies#{" matching #{find.to_s.strip.inspect}" if find.present?}: #{counts}. Of the #{TRACKING.key(tab)}: #{within}."
        end

        def shown(total, from, size, needs)
          which = needs.present? ? " (#{needs.tr('_', ' ')})" : ""
          return "None#{which}." if total.zero?
          return "None past #{from}: there are #{total}#{which}." if size.zero?

          more = from + size < total ? " Next: offset #{from + size}." : ""
          "Showing #{from + 1} to #{from + size} of #{total}#{which}, ids for track_or_archive_companies and get_company_status.#{more}"
        end

        def line(company, roles, application, checked, tab)
          head, detail = WatchList.roles_line(company.id, roles)
          said = [ head.presence, (detail.presence && "(#{detail})") ].compact.join(" ").presence || "none"
          at = application && "#{Application.stage_label(application.stage)} (#{application.posting.role_title})"
          "- #{company.name} (#{company.domain || 'no domain'})#{", #{Verifier::Tracking.label(company.tracking)}" if tab == 'all' && !company.tracked?}, id #{company.id}\n" \
            "  careers page: #{page(company)}; roles: #{said}; application: #{at || 'none'}; " \
            "last checked: #{checked ? checked.utc.to_date.iso8601 : 'never'}"
        end

        def page(company)
          case company.resolution_status
          when "resolved" then company.kind == "aggregator" ? "on record, not watched (an aggregator)" : "watched at #{company.careers_page_url}"
          when "candidate" then "to confirm: #{company.resolution_candidate_url}"
          when "failed" then "none found"
          else "not looked for yet"
          end
        end
      end
    end
  end
end
