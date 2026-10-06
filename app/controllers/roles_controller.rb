# The roles being watched: postings, in the operator's words.
class RolesController < ApplicationController
  TABS = %w[tracked suggested dismissed].freeze
  # Tracked roles are grouped by their answer, the ones that changed first.
  GROUPS = %w[not_found verified_live inaccessible pending].freeze

  def index
    @tab = TABS.include?(params[:tab]) ? params[:tab] : "tracked"
    @counts = Posting.group(:tracking).count
    @roles = Posting.where(tracking: @tab).joins(:company).includes(:company)
                    .order("companies.name", :role_title)
  end

  def show
    @role = Posting.includes(:company).find(params[:id])
    @history = @role.audit_events.order(occurred_at: :desc)
    # The checks whose matching said something about this role, newest first.
    @checks = @role.company.page_checks.where("matches @> ?", [ { posting_id: @role.id } ].to_json)
                   .order(checked_at: :desc).limit(10)
  end
end
