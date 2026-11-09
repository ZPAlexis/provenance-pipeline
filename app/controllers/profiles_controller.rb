# The search profile: what the operator is looking for, edited here and audited
# when saved. Preview weighs the profile on the page, saved or not, against the
# roles every watched page last listed, and writes nothing.
class ProfilesController < ApplicationController
  def show
    @profile = SearchProfile.current || SearchProfile.new(work_modes: SearchProfile::WORK_MODES)
    @resumes = @profile.persisted? ? @profile.resumes.newest_first.to_a : []
  end

  # The resume pasted below the profile (2b): a new version when its text changed, audited by size and hash.
  def resume
    profile = SearchProfile.current or return redirect_to(profile_path, alert: "Save the profile first: the resume is kept with it.",
                                                                        status: :see_other)
    kept = Resumes.keep!(profile, text: params[:resume_text])
    redirect_to profile_path(anchor: "resume"), status: :see_other,
                                                notice: kept ? "Resume saved: #{kept.words} words." : "Nothing to save: it is the same text as now."
  rescue ArgumentError => e
    redirect_to profile_path(anchor: "resume"), alert: "Not saved: #{e.message}.", status: :see_other
  end

  def remove_resume
    profile = SearchProfile.current
    removed = profile ? Resumes.remove!(profile) : raise(ArgumentError, "there is no resume to remove")
    redirect_to profile_path(anchor: "resume"), notice: "Resume deleted, with all #{removed} of its saved versions.", status: :see_other
  rescue ArgumentError => e
    redirect_to profile_path(anchor: "resume"), alert: "#{e.message.upcase_first}.", status: :see_other
  end

  # What the operator wants of a company (4b), its own form: saved as theirs through CompanyPreferences, which audits
  # their own words by a hash alone. Saving it finds no suggestions (role suggestions read the rest of the profile); a
  # company review read against the preferences before is stale from now on.
  def company_preferences
    profile = SearchProfile.current or return redirect_to(profile_path(anchor: "company"), alert: "Save the profile first: the company " \
                                                                                                  "preferences are kept with it.", status: :see_other)
    saved = CompanyPreferences.save!(profile, company_preference_params.to_h)
    due = CompanyReviews.due(profile: profile).count
    said = "#{helpers.pluralize(due, 'company')} tracked or proposed #{due == 1 ? 'is' : 'are'} due a review against them." if profile.company_preferences?
    redirect_to profile_path(anchor: "company"), status: :see_other,
                                                 notice: saved ? "Company preferences saved. #{said}".strip : "Nothing to save: they are as they were."
  rescue ArgumentError => e
    redirect_to profile_path(anchor: "company"), alert: "Not saved: #{e.message}.", status: :see_other
  end

  def update
    @profile = editing
    return render(:show, status: :unprocessable_content) unless @profile.valid?

    SearchProfile.transaction do
      @profile.save!
      # The company preferences (4b) in the operator's own words, by a hash alone.
      AuditEvent.record_write!(@profile, actor: AuditEvent::OPERATOR, reasoning: "Saved on the Profile page.",
                                         digest: CompanyPreferences::PRIVATE)
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

  # The lists of words come as text, one per line (or comma-separated); the stages, sizes and models ticked.
  def company_preference_params
    params.expect(company_preferences: [ :company_wants, :company_avoids, :company_industries, :company_excluded,
                                         company_stages: [], company_sizes: [], company_models: [] ])
  end
end
