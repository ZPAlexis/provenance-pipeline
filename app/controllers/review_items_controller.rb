# The review queue: what an agent saw that needs the operator's judgment
# (ReviewQueue), and the operator's decisions on it, each carried out through the
# service that makes that write, audited as theirs.
class ReviewItemsController < ApplicationController
  DECISIONS = %w[confirm reject set_page set_kind find_again check_again still_listed no_longer_listed undo leave].freeze
  DONE = {
    "confirm" => "Confirmed: its careers page is watched. Check it now to read its roles.",
    "reject" => "Rejected: set the right page by hand if you know it.",
    "set_page" => "Set: its careers page is watched. Check it now to read its roles.",
    "set_kind" => "Its kind is set.",
    "still_listed" => "Recorded: still listed, as you saw it.",
    "no_longer_listed" => "Recorded: no longer listed, as you saw it.",
    "undo" => "The verdict is undone.",
    "leave" => "Left as is: it comes back only if what was seen changes."
  }.freeze

  def index
    @counts = ReviewItem.open.group(:kind).count
    @kind = params[:kind] if ReviewItem::KINDS.include?(params[:kind])
    items = ReviewItem.open.includes(:company, :subject).oldest_first
    @items = @kind ? items.where(kind: @kind) : items
  end

  def decide
    item = ReviewItem.includes(:company, :subject).find(params[:id])
    return redirect_back_or_to(review_path, alert: "That item is already decided.", status: :see_other) unless item.status == "open"

    decision = params[:decision].to_s
    raise ArgumentError, "unknown decision #{decision.inspect}" unless DECISIONS.include?(decision)

    redirect_back_or_to review_path, notice: carry_out(item, decision), status: :see_other
  rescue ArgumentError, Verifier::Candidates::NotACandidate, ActiveRecord::RecordInvalid => e
    redirect_back_or_to review_path, alert: e.message.upcase_first, status: :see_other
  end

  private

  def carry_out(item, decision)
    return check(item, decision == "find_again" ? item.company : item.subject) if %w[find_again check_again].include?(decision)

    company, role, note = item.company, item.subject, params[:note].to_s.strip.presence
    ReviewQueue.decide!(item, decision, note: note) do
      case decision
      when "confirm" then Verifier::Candidates.confirm!(company)
      when "reject" then Verifier::Candidates.reject!(company)
      when "set_page" then Verifier::Candidates.set_page!(company, params[:url].to_s.strip, reasoning: note)
      when "set_kind" then Verifier::Candidates.set_kind!(company, params[:kind].to_s, reasoning: note)
      when "still_listed", "no_longer_listed"
        Verifier::HandCheck.record!(role, verdict: decision == "still_listed" ? "verified_live" : "not_found", note: note)
      when "undo" then Verifier::HandCheck.undo_verdict!(role, reasoning: note)
      end
    end
    DONE.fetch(decision)
  end

  # A check from the queue: the item stays open, and closes when the check settles it.
  def check(item, record)
    raise ArgumentError, "#{item.kind.humanize} is no longer on record" unless record
    if (why = Verifier::CheckNow.refusal(record))
      raise ArgumentError, why
    end

    CheckRun.start_for!(record)
    "Checking it now, in the background. The item closes if the check settles it."
  end
end
