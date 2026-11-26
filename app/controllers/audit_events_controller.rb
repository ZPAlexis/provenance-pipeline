# The audit log, searchable (3.1): every write on record, narrowed from the page. Read-only. Since 4e step 11 a second
# tab, "Check results", lists what a check of all tracked companies found (what the What changed page showed): one
# table, newest first, from the record alone.
class AuditEventsController < ApplicationController
  # The page's names for the log's filters: `action` is the router's own parameter, so the action filter is `act`.
  PARAMS = (AuditLog::FILTERS - %i[action] + %i[act]).freeze

  def index
    filters = params.permit(*PARAMS).to_h.symbolize_keys
    @log = AuditLog.new(**filters.except(:act), action: filters[:act])
    @pages = @log.pages
    @page = params[:page].to_i.clamp(1, @pages)
    @events = @log.page(@page)
    @by_who = @log.by_who
    @kinds = AuditLog.kinds
    @attributes = AuditLog.attributes(@log.kind)
    check_results
  rescue ArgumentError => e
    redirect_to audit_path, alert: e.message.upcase_first, status: :see_other
  end

  private

  # The Check results tab: since the point chosen (a check of all tracked companies), narrowed to a kind or to what
  # needs the operator, a page of AuditLog::PER_PAGE at a time. Opened first when asked for (view=checks): a link
  # carries that, since a redirect drops a #tab.
  def check_results
    @view = params[:view] == "checks" ? "checks" : "every"
    @points = WhatChanged.points
    @point = WhatChanged.point(params[:since])
    rows = WhatChanged.new(@point.at).rows
    @result_counts = rows.map(&:kind).tally
    @needs_you = rows.count(&:needs_you)
    @rows_total = rows.size
    @result = params[:result] if params[:result] == "needs_you" || WhatChanged::KINDS.key?(params[:result])
    rows = @result == "needs_you" ? rows.select(&:needs_you) : rows.select { |row| row.kind == @result } if @result
    @results_pages = [ (rows.size / AuditLog::PER_PAGE.to_f).ceil, 1 ].max
    @results_page = params[:results_page].to_i.clamp(1, @results_pages)
    @results_count = rows.size
    @results = rows.slice((@results_page - 1) * AuditLog::PER_PAGE, AuditLog::PER_PAGE) || []
  end
end
