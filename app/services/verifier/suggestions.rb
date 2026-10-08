module Verifier
  # Roles on watched pages that fit the search profile, weighed by the worker's
  # `suggest` command against the roles each page last listed: nothing is
  # fetched, and nothing is paid for. Any agent weighing roles against the
  # profile goes through the same command, so they all weigh alike.
  module Suggestions
    # One role holding a profile title: suggested, or ruled out by `ruled_out`, with the worker's reasoning.
    Fit = Data.define(:company, :listing, :title, :level, :place, :work_mode, :suggested, :ruled_out, :notes, :reasoning)

    # What a profile would suggest now. `unread`: watched companies whose page has no read to weigh;
    # `problems`: companies whose result could not be used, and why.
    Preview = Data.define(:companies, :unread, :weighed, :read_between, :fits, :problems) do
      def suggested = fits.select(&:suggested)
      def ruled_out = fits.reject(&:suggested)
    end

    FIT_FIELDS = %w[listing title level place work_mode suggested ruled_out notes reasoning].freeze

    module_function

    # What `profile` (saved or not) would suggest from every watched company's
    # latest list. Writes nothing, and keeps nothing: the run's files are removed.
    def preview(profile, worker: Worker.new(run_dir: Worker.dir_for("suggest")))
      companies = Company.watched.order(:name).to_a
      targets = companies.filter_map { |company| Targets.suggest(company, profile) }
      read_at = PageCheck.where(id: targets.pluck(:page_check_id)).pluck(:checked_at)
      empty = { companies: targets.size, unread: companies.size - targets.size, read_between: read_at.minmax }
      return Preview.new(**empty, weighed: 0, fits: [], problems: []) if targets.empty?

      run = worker.run(targets, command: "suggest")
      fits, weighed, problems = weigh(run.results, companies.index_by(&:id))
      problems << "The worker stopped early: #{run.stopped}." if run.stopped
      Preview.new(**empty, weighed: weighed, fits: fits, problems: problems)
    ensure
      FileUtils.rm_rf(run.dir) if run
    end

    # Each result checked against the contract before any of it is shown.
    def weigh(results, companies)
      problems = []
      weighed = 0
      fits = results.flat_map do |result|
        company = companies[result["target_id"]] if result.is_a?(Hash)
        problem = ResultContract.suggestion_errors(result).first
        problem ||= "not a watched company" unless company
        problem ||= result["reason"] || "the worker failed" unless result["outcome"] == "ok"
        if problem
          problems << "#{company&.name || result.to_h['target_id']}: #{problem}"
          next []
        end

        weighed += result["weighed"]
        result["roles"].map { |role| Fit.new(company: company, **FIT_FIELDS.to_h { |field| [ field.to_sym, role[field] ] }) }
      end
      [ fits, weighed, problems ]
    end
  end
end
