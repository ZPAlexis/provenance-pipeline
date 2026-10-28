# The review queue: what an agent saw that needs the operator's judgment
# (ReviewQueue), and the operator's decisions on it, each carried out through the
# service that makes that write, audited as theirs.
class ReviewItemsController < ApplicationController
  # The kinds whose items offer a check, and what is checked: the company, or the role asked about.
  CHECKED = { "no_careers_page" => "company", "suspect_verdict" => "role", "unconfirmed_role" => "role" }.freeze

  def index
    @counts = ReviewItem.open.group(:kind).count
    @kind = params[:kind] if ReviewItem::KINDS.include?(params[:kind])
    @recommended = params[:recommended] == "1"
    items = ReviewItem.open
    items = items.where(kind: @kind) if @kind
    @recommended_count = items.recommended.count
    @recommended_total = ReviewItem.open.recommended.count
    items = items.recommended if @recommended
    @items = items.includes(:company, :subject).oldest_first
    @runs = latest_checks(@items)
    @agreement = ReviewRecommendations.agreement
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

  # The item's recommendation accepted in one click (2g): carried out as the operator's decision, noting they followed it.
  def accept
    item = ReviewItem.includes(:company, :subject).find(params[:id])
    done = ReviewRecommendations.accept!(item, check: ->(record) { CheckRun.start_for!(record) })
    redirect_back_or_to review_path, notice: done, status: :see_other
  rescue ArgumentError, Verifier::Candidates::NotACandidate, ActiveRecord::RecordInvalid => e
    redirect_back_or_to review_path, alert: e.message.upcase_first, status: :see_other
  end

  private

  # The latest check of each item's company or role started since the item was
  # raised, by item id: shown on the item, so a check asked from here can be followed.
  def latest_checks(items)
    items = items.select { |item| CHECKED.key?(item.kind) }
    return {} if items.empty?

    runs = CheckRun.where(company_id: items.map(&:company_id), created_at: items.map(&:created_at).min..).newest_first.to_a
    items.to_h do |item|
      [ item.id, runs.find do |run|
        run.created_at >= item.created_at && (CHECKED[item.kind] == "role" ? run.posting_id == item.subject_id : run.kind == "company")
      end ]
    end.compact
  end
end
