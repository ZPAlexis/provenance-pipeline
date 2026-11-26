# What changed since a check of all tracked companies (1.4) is the audit log's Check results since 4e step 11: the
# page's old address leads there, the point it compared from kept.
class ChangesController < ApplicationController
  def index
    redirect_to audit_path({ view: "checks", since: params[:from].presence }.compact), status: :moved_permanently
  end
end
