# The audit log, searchable (3.1): every write on record, narrowed from the page. Read-only.
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
  rescue ArgumentError => e
    redirect_to audit_path, alert: e.message.upcase_first, status: :see_other
  end
end
