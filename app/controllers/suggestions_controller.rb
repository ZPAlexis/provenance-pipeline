# "Find suggestions": every watched company's latest list weighed against the
# saved search profile, and the suggestions brought up to date, at no cost.
# Written as agent:suggester (Verifier::Suggestions), which backs up first.
class SuggestionsController < ApplicationController
  def create
    refresh = Verifier::Suggestions.refresh!
    if refresh.run_id.nil? && refresh.problems.any?
      redirect_to profile_path, alert: "#{refresh.problems.first} Save one first.", status: :see_other
    else
      redirect_back_or_to roles_path(tab: "suggested"), notice: refresh.summary, status: :see_other
    end
  rescue Verifier::Worker::Error => e
    redirect_back_or_to roles_path(tab: "suggested"), alert: "Suggestions could not be found: #{e.message}", status: :see_other
  end
end
