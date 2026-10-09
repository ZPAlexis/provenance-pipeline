# The search profile: what the operator is looking for, edited here and audited
# when saved. Preview weighs the profile on the page, saved or not, against the
# roles every watched page last listed, and writes nothing.
class ProfilesController < ApplicationController
  def show
    @profile = SearchProfile.current || SearchProfile.new(work_modes: SearchProfile::WORK_MODES)
  end

  def update
    @profile = editing
    return render(:show, status: :unprocessable_content) unless @profile.valid?

    SearchProfile.transaction do
      @profile.save!
      AuditEvent.record_write!(@profile, actor: AuditEvent::OPERATOR, reasoning: "Saved on the Profile page.")
    end
    # What the saved profile suggests now: the suggestions follow it.
    redirect_to profile_path, notice: "Profile saved. #{Verifier::Suggestions.refresh!(profile: @profile).summary}",
                              status: :see_other
  rescue Verifier::Worker::Error => e
    redirect_to profile_path, alert: "Profile saved, but suggestions could not be found: #{e.message}", status: :see_other
  end

  def preview
    @profile = editing
    @preview = Verifier::Suggestions.preview(@profile) if @profile.valid?
    render :preview, status: @preview ? :ok : :unprocessable_content
  end

  # Titles in the same area as the profile on the page, saved or not: one AI call proposes
  # them, a free preview counts what each would add, and the operator picks. Nothing is saved.
  def related
    @profile = editing
    return render(:related, status: :unprocessable_content) unless @profile.valid?

    @related = Verifier::RelatedTitles.propose(@profile)
    render :related
  rescue Verifier::Worker::Error => e
    @related = Verifier::RelatedTitles::Result.new(proposals: [], cost_usd: 0.0, problems: [ e.message.upcase_first ])
    render :related
  end

  private

  def editing
    (SearchProfile.current || SearchProfile.new).tap { |profile| profile.assign_attributes(profile_params) }
  end

  def profile_params
    params.expect(search_profile: [ :titles_text, :excluded_words_text, :places_text, work_modes: [], levels: [] ])
  end
end
