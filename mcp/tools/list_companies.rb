module ProvenanceMcp
  module Tools
    # The companies on the watch list as the Companies page lists them (4a step 4, WatchList): tracked, proposed (4b),
    # archived or all, narrowed to what needs a look, to a fit (4b: by each one's newest company review, or those due a
    # review) or to words, each with its id, domain, careers page, roles, application, last check and fit (a proposal:
    # where it was found and what its board listed), a page at a time, in name order or best fit first. The companies'
    # text is the record's, between markers.
    class ListCompanies < ReadTool
      PAGE = 50
      # The tool's words for the page's tabs and filters: "archived" is stored "dismissed", "proposed" "suggested".
      TRACKING = { "tracked" => "tracked", "proposed" => "suggested", "archived" => "dismissed", "all" => "all" }.freeze
      NEEDS = { "no_careers_page" => "no_page", "page_to_confirm" => "to_confirm", "no_role_tracked" => "none_tracked",
                "none_still_listed" => "none_listed" }.freeze
      # The page's fit filters, and those due a review: tracked or proposed with none against the preferences as they are.
      FIT = { "85_and_up" => "85", "70_and_up" => "70", "50_and_up" => "50", "not_reviewed" => "none", "stale" => "stale",
              "due_a_review" => "due" }.freeze

      tool_name "list_companies"
      title "List the companies"
      description "The companies on the watch list, as the app's Companies page lists them: those the operator tracks " \
                  "(the default), those proposed to them and waiting, those archived, or all; narrowed, when asked, to " \
                  "what needs a look (no careers page yet, a careers page to confirm, no role tracked, or roles tracked " \
                  "none of which is still listed), to a fit by each one's newest company review (85, 70 or 50 and up, " \
                  "not reviewed, stale, or due a review: none against the preferences as they are), or to words in a " \
                  "name, a domain or a place it hires in. Each with its id, domain, careers page, its roles (tracked and " \
                  "suggested, the tracked ones by answer, archived), its application, its last check and its fit; a " \
                  "proposal with where it was found and what its board listed. #{PAGE} a page, in name order or best " \
                  "fit first: give offset for the next."
      input_schema(
        properties: {
          tracking: { type: "string", enum: TRACKING.keys, description: "Which companies: tracked (the default), proposed, archived, or all" },
          needs: { type: "string", enum: NEEDS.keys, description: "Only those that need this look" },
          fit: { type: "string", enum: FIT.keys, description: "Only those of this fit, by their newest company review" },
          best_first: { type: "boolean", description: "Best fit first, those not reviewed last (name order unless said)" },
          find: { type: "string", description: "Words in a company's name, its domain, or a place it hires in" },
          offset: { type: "integer", description: "How many to skip, for the next page" }
        }
      )

      class << self
        def answer(tracking: "tracked", needs: nil, fit: nil, best_first: false, find: nil, offset: 0)
          tab = TRACKING.fetch(tracking.to_s) { raise Refusal, "tracking is one of #{TRACKING.keys.join(', ')}." }
          filter = NEEDS.fetch(needs.to_s) { raise Refusal, "needs is one of #{NEEDS.keys.join(', ')}." } if needs.present?
          fitting = FIT.fetch(fit.to_s) { raise Refusal, "fit is one of #{FIT.keys.join(', ')}." } if fit.present?
          profile = SearchProfile.current
          found = Company.matching(find.to_s.strip.presence)
          tabs, filters = WatchList.counts(found, tab)
          narrowed = WatchList.narrow(WatchList.in_tab(found, tab), filter)
          fits = WatchList.fit_counts(narrowed, profile: profile).merge("due" => due(narrowed, profile).count)
          companies = (fitting == "due" ? due(narrowed, profile) : WatchList.by_fit(narrowed, fitting, profile: profile)).to_a
          reviews = WatchList.reviews(companies.map(&:id))
          companies = companies.sort_by { |company| [ (best_first ? -(reviews[company.id]&.score || -1) : 0), company.name.downcase, company.name ] }
          from = [ offset.to_i, 0 ].max
          page = companies[from, PAGE] || []
          ids = page.map(&:id)
          roles, applications, checked = WatchList.role_counts(ids), WatchList.applications(ids), WatchList.last_checked(ids)
          lines = page.map { |company| line(company, roles, applications[company.id], checked[company.id], tab, reviews[company.id], profile) }

          ProvenanceMcp.text(summary(tabs, filters, fits, tab, find), shown(companies.size, from, page.size, [ needs, fit ].compact_blank),
                             (Writing.fence("record", lines.join("\n")) if lines.any?))
        end

        private

        # Those due a review: tracked or proposed, with none against the preferences and places as they are now.
        def due(scope, profile) = CompanyReviews.due(scope.where(tracking: %w[tracked suggested]), profile: profile)

        def summary(tabs, filters, fits, tab, find)
          counts = TRACKING.map { |word, stored| "#{word} #{tabs.fetch(stored)}" }.join(", ")
          within = WatchList::FILTERS.map { |key, (label, *)| "#{label.downcase} #{filters.fetch(key)}" }.join(", ") unless tab == "suggested"
          fitted = FIT.map { |word, key| "#{word.tr('_', ' ')} #{fits.fetch(key)}" }.join(", ")
          "Companies#{" matching #{find.to_s.strip.inspect}" if find.present?}: #{counts}. Of the #{TRACKING.key(tab)}: " \
            "#{"#{within}; " if within}by fit: #{fitted}."
        end

        def shown(total, from, size, narrowed)
          which = narrowed.any? ? " (#{narrowed.map { |word| word.tr('_', ' ') }.join(', ')})" : ""
          return "None#{which}." if total.zero?
          return "None past #{from}: there are #{total}#{which}." if size.zero?

          more = from + size < total ? " Next: offset #{from + size}." : ""
          "Showing #{from + 1} to #{from + size} of #{total}#{which}, ids for track_or_archive_companies and get_company_status.#{more}"
        end

        def line(company, roles, application, checked, tab, review, profile)
          head, detail = WatchList.roles_line(company.id, roles)
          said = [ head.presence, (detail.presence && "(#{detail})") ].compact.join(" ").presence || "none"
          at = application && "#{Application.stage_label(application.stage)} (#{application.posting.role_title})"
          fit = review ? "#{review.score}#{' (stale: the preferences or places changed since)' if review.stale?(profile)}" : "not reviewed"
          proposal = company.proposal if company.suggested? && company.proposal.present?
          "- #{company.name} (#{company.domain || 'no domain'})#{", #{state(company)}" if tab == 'all' && !company.tracked?}, id #{company.id}\n" \
            "  careers page: #{page(company)}; roles: #{said}; application: #{at || 'none'}; " \
            "last checked: #{checked ? checked.utc.to_date.iso8601 : 'never'}; fit: #{fit}" +
            (proposal ? "\n  proposed: found by #{Verifier::Proposals::SOURCES.fetch(proposal['source'].to_s, 'another source')}" \
                        "#{" (#{proposal['query']})" if proposal['query']}; its board: #{Verifier::Proposals.seen_said(proposal['seen'])}" : "")
        end

        def state(company) = company.suggested? ? "proposed" : Verifier::Tracking.label(company.tracking)

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
