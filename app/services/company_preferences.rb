# What the operator wants of a company (4b), kept on the search profile beside what they look for in a role: saved by
# the operator, or by their own Claude client on their word (company_preferences:write, those fields alone). What they
# want and avoid, in their words, and the words to avoid, are their own business: the audit log holds them by a hash
# alone, and a save carries a fixed reasoning, never a reason restated in its own words.
module CompanyPreferences
  FIELDS = SearchProfile::COMPANY_PREFERENCES
  LISTS = %w[company_stages company_sizes company_models company_industries company_excluded].freeze
  PRIVATE = %w[company_wants company_avoids company_excluded].freeze

  module_function

  # Saves the fields given, as a hash or as keywords (others are left as they are); a list may come as a list, or as text
  # split on lines and commas. Returns the profile, or nil when nothing changed.
  def save!(profile, given = {}, actor: AuditEvent::OPERATOR, **fields)
    raise ArgumentError, "save the search profile first: the company preferences are kept with it" unless profile&.persisted?

    given = given.to_h.merge(fields)

    unknown = given.to_h.keys.map(&:to_s) - FIELDS
    raise ArgumentError, "only the company preferences are saved here, not #{unknown.join(', ')}" if unknown.any?

    profile.assign_attributes(given.to_h.to_h { |field, value| [ field.to_s, LISTS.include?(field.to_s) ? list(value) : value.to_s ] })
    return unless profile.changed?
    raise ArgumentError, profile.errors.full_messages.to_sentence.downcase_first unless profile.valid?

    ApplicationRecord.transaction do
      profile.save!
      AuditEvent.record_write!(profile, actor: actor, digest: PRIVATE,
                                        reasoning: "Company preferences saved #{Verifier::Tracking.by(actor)}.")
    end
    profile
  end

  # The preferences in words, for the commands and the client: empty when none is set.
  def said(profile)
    return [] unless profile&.company_preferences?

    [ ("Wants: #{profile.company_wants}" if profile.company_wants),
      ("Avoids: #{profile.company_avoids}" if profile.company_avoids),
      ("Stages: #{profile.company_stages.map { |stage| SearchProfile::COMPANY_STAGES.fetch(stage) }.join(', ')}" if profile.company_stages.any?),
      ("Sizes: #{profile.company_sizes.join(', ')} people" if profile.company_sizes.any?),
      ("Business models: #{profile.company_models.map { |model| SearchProfile::COMPANY_MODELS.fetch(model) }.join(', ')}" if profile.company_models.any?),
      ("Industries: #{profile.company_industries.join(', ')}" if profile.company_industries.any?),
      ("Words to avoid: #{profile.company_excluded.join(', ')}" if profile.company_excluded.any?) ].compact
  end

  def list(value) = value.is_a?(Array) ? value : value.to_s.split(/[\n,]/)

  private_class_method :list
end
