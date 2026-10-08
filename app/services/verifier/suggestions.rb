module Verifier
  # Roles on watched pages that fit the search profile, weighed by the worker's
  # `suggest` command against the roles each page last listed: nothing is
  # fetched, and nothing is paid for. Any agent weighing roles against the
  # profile goes through the same command, so they all weigh alike.
  #
  # A refresh writes suggestions as agent:suggester. Only the operator tracks or
  # dismisses a role; the suggester never touches one they acted on, and never
  # suggests anew a role already on record (dismissed ones included), matched as
  # verification matches. A suggestion the operator never acted on is withdrawn
  # (deleted, its whole record kept in the audit) when it no longer fits the
  # profile, or when its latest check found it gone from the whole list.
  module Suggestions
    ACTOR = "agent:suggester".freeze
    # One refresh writes at a time: a check finishing as the profile is saved must not suggest a role twice.
    LOCK = 0x5355_4747

    # One role holding a profile title: suggested, or ruled out by `ruled_out`, with the worker's reasoning.
    # `on_record`: the posting it already is, or nil.
    Fit = Data.define(:company, :listing, :title, :level, :place, :work_mode, :suggested, :ruled_out, :notes, :reasoning,
                      :on_record)

    # What a profile would suggest now. `unread`: watched companies whose page has no read to weigh;
    # `problems`: companies whose result could not be used, and why.
    Preview = Data.define(:companies, :unread, :weighed, :read_between, :fits, :problems) do
      def suggested = fits.select(&:suggested)
      def ruled_out = fits.reject(&:suggested)
      def new_roles = suggested.reject(&:on_record)
      def on_record = suggested.select(&:on_record)
    end

    # What a refresh wrote, and what it could not weigh.
    Refresh = Data.define(:created, :updated, :withdrawn, :problems, :run_id) do
      def summary
        changes = [ "#{created} new", ("#{updated} updated" if updated.positive?), ("#{withdrawn} withdrawn" if withdrawn.positive?) ]
        not_weighed = " Not weighed: #{problems.first(2).join(' ')}#{" (#{problems.size - 2} more)" if problems.size > 2}" if problems.any?
        "Suggestions: #{changes.compact.join(', ')}.#{not_weighed}"
      end
    end

    FIT_FIELDS = %w[listing title level place work_mode suggested ruled_out notes reasoning].freeze

    module_function

    # What `profile` (saved or not) would suggest from every watched company's
    # latest list. Writes nothing, and keeps nothing: the run's files are removed.
    def preview(profile, worker: Worker.new(run_dir: Worker.dir_for("suggest")))
      companies = Company.watched.order(:name).to_a
      targets = companies.filter_map { |company| Targets.suggest(company, profile) }
      read_at = PageCheck.where(id: targets.pluck(:page_check_id)).pluck(:checked_at)
      shown = { companies: targets.size, unread: companies.size - targets.size, read_between: read_at.minmax }
      return Preview.new(**shown, weighed: 0, fits: [], problems: []) if targets.empty?

      run = worker.run(targets, command: "suggest")
      results, problems = usable(run, companies)
      postings = Posting.where(company_id: results.map { |company, _| company.id }).index_by(&:id)
      fits = results.flat_map { |company, result| result["roles"].map { |role| fit(company, role, postings) } }
      Preview.new(**shown, weighed: results.sum { |_, result| result["weighed"] }, fits: fits, problems: problems)
    ensure
      FileUtils.rm_rf(run.dir) if run
    end

    # Writes what the saved profile suggests at `companies` (every watched one by
    # default): each fitting role not on record becomes a suggestion; each one
    # already suggested has its fit brought up to date; one no longer fitting, or
    # no longer listed, is withdrawn. Backs up first, at most once a day.
    def refresh!(companies = Company.watched, profile: SearchProfile.current,
                 worker: Worker.new(run_dir: Worker.dir_for("suggest")))
      nothing = { created: 0, updated: 0, withdrawn: 0, run_id: nil }
      return Refresh.new(**nothing, problems: [ "No search profile is saved yet." ]) unless profile&.persisted?

      companies = companies.to_a
      targets = companies.filter_map { |company| Targets.suggest(company, profile) }
      return Refresh.new(**nothing, problems: []) if targets.empty?

      run = worker.run(targets, command: "suggest")
      results, problems = usable(run, companies)
      DatabaseBackup.daily
      tally = Hash.new(0)
      ApplicationRecord.transaction do
        ApplicationRecord.connection.execute("SELECT pg_advisory_xact_lock(#{LOCK})")
        results.each { |company, result| write(company, result, profile, run.id, tally) }
      end
      Refresh.new(created: tally[:created], updated: tally[:updated], withdrawn: tally[:withdrawn], problems: problems,
                  run_id: run.id)
    end

    # The run's results that may be used, each with its company, checked against
    # the contract before any of it is shown or written; and why any other could not be.
    def usable(run, companies)
      by_id = companies.index_by(&:id)
      problems = []
      results = run.results.filter_map do |result|
        company = by_id[result["target_id"]] if result.is_a?(Hash)
        problem = ResultContract.suggestion_errors(result).first
        problem ||= "not a watched company" unless company
        problem ||= result["reason"] || "the worker failed" unless result["outcome"] == "ok"
        next [ company, result ] unless problem

        problems << "#{company&.name || result.to_h['target_id']}: #{problem}"
        nil
      end
      problems << "The worker stopped early: #{run.stopped}." if run.stopped
      [ results, problems ]
    end

    def fit(company, role, postings)
      Fit.new(company: company, on_record: postings[role["on_record"]], **FIT_FIELDS.to_h { |field| [ field.to_sym, role[field] ] })
    end

    # One company's result: new suggestions, refits, withdrawals.
    def write(company, result, profile, run_id, tally)
      check = company.page_checks.find(result["page_check_id"])
      postings = company.postings.to_a.index_by(&:id)
      fitting = result["roles"].select { |role| role["suggested"] }
      fitting.each do |role|
        posting = postings[role["on_record"]]
        if posting.nil?
          tally[:created] += 1 if suggest!(company, role, check, profile, result["weighed"], run_id)
        elsif posting.tracking == "suggested"
          tally[:updated] += 1 if refit!(posting, role, profile, run_id)
        end
      end

      fits_now = fitting.filter_map { |role| role["on_record"] }.to_set
      postings.each_value do |posting|
        next if posting.tracking != "suggested" || fits_now.include?(posting.id)

        why = withdrawal(posting, result) or next
        AuditEvent.record_destroy!(posting, actor: ACTOR, reasoning: "Withdrawn: #{why} Run #{run_id}.")
        posting.destroy!
        tally[:withdrawn] += 1
      end
    end

    def suggest!(company, role, check, profile, weighed, run_id)
      listing = role["listing"]
      url = listing["url"] if ResultContract.web_url?(listing["url"])
      # A guard, not the rule (the worker matched it against everything on record): never twice by one link.
      return false if url ? company.postings.exists?(job_url: url) : company.postings.exists?(role_title: listing["title"], location: listing["location"])

      posting = company.postings.create!(
        role_title: listing["title"], location: listing["location"], job_url: url, tracking: "suggested",
        fit: fit_record(role, profile),
        # As its company's page listed it when read: still listed then.
        verification_state: "verified_live", last_checked_at: check.checked_at, roles_listed_count: weighed,
        work_mode: (role["work_mode"] unless role["work_mode"] == "unknown")
      )
      AuditEvent.record_write!(
        posting, actor: ACTOR,
        reasoning: "Suggested: #{role['reasoning']} Listed on its company's careers page when read at " \
                   "#{check.checked_at.utc.iso8601} (check #{check.id}, run #{check.run_id}). Run #{run_id}."
      )
      true
    end

    # A suggestion that still fits, with its reasons as weighed now; audited only when they changed.
    def refit!(posting, role, profile, run_id)
      posting.update!(fit: fit_record(role, profile))
      AuditEvent.record_write!(posting, actor: ACTOR, reasoning: "Still fits: #{role['reasoning']} Run #{run_id}.").present?
    end

    # Why a suggestion no longer stands, or nil when it may: one this read did not show
    # stays until a check finds it gone from the whole list, as a verdict would.
    def withdrawal(posting, result)
      if (index = result["listed"][posting.id])
        role = result["roles"].find { |r| r["listing_index"] == index }
        if role.nil? then "its title no longer holds any of the profile's titles."
        elsif role["suggested"] then "another role on record is the same one."
        else "it no longer fits the profile. #{role['reasoning']}"
        end
      elsif posting.verification_state == "not_found"
        "it is no longer listed: its latest check found it gone from the whole list."
      end
    end

    # How the role fits, as stored on it for the operator and the agents to come.
    def fit_record(role, profile)
      { "profile_id" => profile.id, **role.slice("title", "place", "level", "work_mode", "notes", "reasoning") }
    end
  end
end
