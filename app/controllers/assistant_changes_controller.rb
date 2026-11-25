# What the AI assistant changed on a page's record since the page was opened (4e): asked for by the page every 20
# seconds, as a check run's frame asks while it runs, and answered from the audit log alone. Writes nothing. A record
# gone since (a suggestion withdrawn) stops the asking, saying nothing.
class AssistantChangesController < ApplicationController
  def show
    record = RecordHistory::KINDS.fetch(params[:kind].to_s).constantize.find_by(id: params[:id])
    return render(partial: "assistant_changes/banner", locals: { said: nil, asking: false }) unless record

    changes = RecordHistory.assistant_changes(record, since: Time.iso8601(params[:since].to_s)).to_a
    render partial: "assistant_changes/banner", locals: { said: RecordHistory.said(changes, record), asking: true }
  rescue ArgumentError
    head :bad_request # no time it was opened, or not one
  end
end
