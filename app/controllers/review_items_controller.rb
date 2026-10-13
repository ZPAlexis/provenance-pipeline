# The review queue: what an agent saw that needs the operator's judgment
# (ReviewQueue), and the operator's decisions on it, each carried out through the
# service that makes that write, audited as theirs.
class ReviewItemsController < ApplicationController
  def index
    @counts = ReviewItem.open.group(:kind).count
    @kind = params[:kind] if ReviewItem::KINDS.include?(params[:kind])
    items = ReviewItem.open.includes(:company, :subject).oldest_first
    @items = @kind ? items.where(kind: @kind) : items
  end

  # A check started from the queue runs in the background; the item closes if it settles it.
  def decide
    item = ReviewItem.includes(:company, :subject).find(params[:id])
    done = ReviewQueue.act!(item, params[:decision].to_s, note: params[:note], url: params[:url], kind: params[:kind],
                                                          check: ->(record) { CheckRun.start_for!(record) })
    redirect_back_or_to review_path, notice: done, status: :see_other
  rescue ArgumentError, Verifier::Candidates::NotACandidate, ActiveRecord::RecordInvalid => e
    redirect_back_or_to review_path, alert: e.message.upcase_first, status: :see_other
  end
end
