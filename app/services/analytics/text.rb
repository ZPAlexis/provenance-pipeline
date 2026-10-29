module Analytics
  # The analytics in plain text (3.3 step 3), for `analytics:report` and the `get_analytics` MCP tool: the same
  # figures as the Analytics page, a section at a time. Figures only: nothing a role, a company or a person wrote.
  module Text
    SECTIONS = %w[pipeline watch agents].freeze
    # How many of the latest weeks and days the text lists; the page shows them all.
    WEEKS = 12
    DAYS = 14

    module_function

    # The sections asked for (all of them when none is), each worked out for the period given.
    def report(sections = SECTIONS, since: nil)
      sections.flat_map { |section| [ *public_send(section, Analytics.public_send(section, since: since)), "" ] }[0...-1]
    end

    def pipeline(report)
      started = report.since ? "the applications started since #{report.since}" : "every application"
      return [ "Pipeline (#{started}): none yet.", *open_now(report) ] if report.applications.zero?

      [ "Pipeline (#{started}): #{count(report.applications, 'application')}.",
        "How far they get (each counted at every stage up to its furthest):",
        *report.steps.map { |step| "  #{label(step.stage)}: #{step.reached}#{step_rate(step)}" },
        "How long they sit (days in each stage, as the operator dated them; one still there counts so far):",
        *report.stays.map do |stay|
          "  #{label(stay.stage)}: #{count(stay.times, 'time')} there, median #{days(stay.median)}, longest #{days(stay.longest)}, " \
          "#{stay.still} still there"
        end,
        "How they end: accepted, #{rate(report.outcome.accepted, report.outcome.closed, 'closed', report.outcome.accepted_rate)}; " \
        "an offer, #{rate(report.outcome.offers, report.outcome.applied, 'applied to', report.outcome.offer_rate)}.",
        *open_now(report) ]
    end

    def watch(report)
      lasting = report.lasting
      fresh = report.freshness
      closed = if lasting.closed.zero? then "none seen gone yet"
      else
        "#{count(lasting.closed, 'role')} since seen gone, median #{days(lasting.closed_median)} days (longest #{days(lasting.closed_longest)})"
      end
      listed = if lasting.listed.zero? then "none listed still"
      else
        "#{lasting.listed} listed still, median #{days(lasting.listed_median)} days so far (longest #{days(lasting.listed_longest)})"
      end
      [ "The watch (#{report.since ? "roles first seen listed, and reads and changes, since #{report.since}" : 'every role'}):",
        "How long roles stay listed (first seen listed to first seen gone, by the checks' own days): #{closed}; #{listed}.",
        "Week by week (weeks start on Monday, UTC; the latest #{WEEKS} with any):",
        *report.weeks.first(WEEKS).map do |week|
          changes = [ ("#{week.gone} to gone" if week.gone.positive?), ("#{week.listed} to listed" if week.listed.positive?),
                      ("#{week.other} to another" if week.other.positive?), ("#{week.by_operator} yours" if week.by_operator.positive?) ].compact
          "  #{week.week}: #{count(week.checked, 'role')} matched by the reads, #{count(week.changed, 'answer')} changed" \
          "#{" (#{changes.join(', ')})" if changes.any?}"
        end,
        ("  none" if report.weeks.empty?),
        "How fresh the answers are now: of #{count(fresh.tracked, 'tracked role')}, #{fresh.fresh} checked in the last " \
        "#{Overview::STALE_AFTER.inspect}, #{fresh.stale} longer ago#{" (the oldest #{count(fresh.oldest, 'day')})" if fresh.stale.positive?}, " \
        "#{fresh.never} never." ].compact
    end

    def agents(report)
      reads = report.reads
      [ "The agents (#{report.since ? "since #{report.since}" : 'all time'}):",
        "What the AI cost: #{dollars(report.cost)} over #{count(report.spend.sum(&:calls), 'call')}.",
        *report.spend.map do |spend|
          "  #{spend.purpose} on #{spend.model}: #{count(spend.calls, 'call')}, #{dollars(spend.cost)}" \
          "#{" (#{(spend.share * 100).round(1)}%)" if spend.share}, #{spend.tokens_in.to_fs(:delimited)} tokens in, " \
          "#{spend.tokens_out.to_fs(:delimited)} out"
        end,
        "By day (the latest #{DAYS} with any), with the running total:",
        *report.days.last(DAYS).reverse.map { |day| "  #{day.day}: #{count(day.calls, 'call')}, #{dollars(day.cost)} (#{dollars(day.running)} so far)" },
        ("  none" if report.days.empty?),
        "Reading the watched pages: #{count(reads.reads, 'verification read')}, #{reads.with_ai} needing the AI, " \
        "#{dollars(reads.cost)} in all; #{reads.per_read ? dollars(reads.per_read) : '—'} a read, " \
        "#{reads.per_confirmed ? dollars(reads.per_confirmed) : '—'} a role confirmed listed (#{count(reads.confirmed, 'role')}).",
        "How the review queue's recommendations came out:",
        *report.agreement.map do |row|
          "  #{ReviewGuidance.label(row.kind)}: #{row.agreed} agreed, #{row.differed} differed, #{row.resolved} resolved on their own, " \
          "#{row.pending} pending; agreement #{row.rate ? "#{row.rate}%" : "too few to say (#{row.decided} decided)"}"
        end,
        ("  none made" if report.agreement.empty?),
        "What each one wrote:",
        *report.actors.map do |row|
          "  #{row.actor}: #{count(row.writes, 'write')}, #{row.refused} refused" \
          "#{", #{count(row.credentials, 'credential')} issued" unless row.actor == 'operator'}"
        end ].compact
    end

    def open_now(report)
      open = report.open.map { |stage| "#{label(stage.stage)} #{stage.applications} (median #{days(stage.median)} days there, longest #{days(stage.longest)})" }
      [ "Open now: #{open.any? ? open.join('; ') : 'none'}. #{count(report.unapplied, 'tracked role')} still listed " \
        "#{report.unapplied == 1 ? 'has' : 'have'} no application." ]
    end

    # The rate from the stage before, when there is one to give: none for the first stage, or when none got that far.
    def step_rate(step)
      return "" if step.before.to_i.zero?

      step.rate ? ", #{step.rate}% of those at the stage before" : ", too few at the stage before to say (#{step.before})"
    end

    def rate(part, whole, noun, rate) = "#{part} of #{whole} #{noun} (#{rate ? "#{rate}%" : 'too few to say'})"

    def label(stage) = Application.stage_label(stage)

    def count(number, noun) = "#{number} #{number == 1 ? noun : noun.pluralize}"

    def days(value) = value.nil? ? "—" : (value.to_f == value.to_i ? value.to_i : value.to_f.round(1))

    # As the pages show money: fractions of a cent show, since most calls cost a cent or less.
    def dollars(amount)
      amount = amount.to_f
      return "$0" if amount.zero?

      amount < 0.1 ? format("$%.3f", amount) : format("$%.2f", amount)
    end

    private_class_method :open_now, :step_rate, :rate, :label, :count, :days, :dollars
  end
end
