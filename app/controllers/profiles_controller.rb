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
    redirect_to profile_path, notice: "Profile saved.", status: :see_other
  end

  def preview
    @profile = editing
    @preview = Verifier::Suggestions.preview(@profile) if @profile.valid?
    render :preview, status: @preview ? :ok : :unprocessable_content
  end

  private

  def editing
    (SearchProfile.current || SearchProfile.new).tap { |profile| profile.assign_attributes(profile_params) }
  end

  def profile_params
    params.expect(search_profile: [ :titles_text, :excluded_words_text, :places_text, work_modes: [], levels: [] ])
  end
end
