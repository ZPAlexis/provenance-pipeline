# The review queue: what an agent saw that needs the operator's judgment (ReviewQueue).
class ReviewItemsController < ApplicationController
  def index
    @counts = ReviewItem.open.group(:kind).count
    @kind = params[:kind] if ReviewItem::KINDS.include?(params[:kind])
    items = ReviewItem.open.includes(:company, :subject).oldest_first
    @items = @kind ? items.where(kind: @kind) : items
  end
end
