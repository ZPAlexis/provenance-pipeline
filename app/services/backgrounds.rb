# The operator's background beyond the resume (4c): kept with the search profile, version by version, and removed only
# as a whole, as the resume is. Audited as the operator's, by each part's size and hash: the log never copies the text.
# No agent may write it (no scope allows it).
module Backgrounds
  module_function

  # Keeps the parts given (as a hash or as keywords) as the background's newest version; nil when they are the same as now.
  def keep!(profile, given = {}, actor: AuditEvent::OPERATOR, **parts)
    raise ArgumentError, "save the profile first: the background is kept with it" unless profile&.persisted?

    background = Background.of(profile, given.to_h.merge(parts))
    Background::PARTS.each do |part, about|
      next unless (text = background.public_send(part)) && text.size > Background::MAX_CHARS

      raise ArgumentError, "\"#{about[:label]}\" is #{text.size} characters, over #{Background::MAX_CHARS}: keep it short, " \
                           "since the fit scorer weighs everything it is given"
    end
    raise ArgumentError, background.errors.full_messages.to_sentence.downcase_first unless background.valid?

    current = newest(profile)
    return if current&.content_hash == background.content_hash

    ApplicationRecord.transaction do
      background.save!
      AuditEvent.record!(actor: actor, action: "create", target: background, changes_made: audited(current, background),
                         reasoning: "Background #{current ? 'changed' : 'saved'} on the Profile page: #{said(background)}.")
      background
    end
  end

  # Removes every version: the background is gone from the record, its audit events naming only sizes and hashes.
  def remove!(profile, actor: AuditEvent::OPERATOR)
    versions = profile&.backgrounds.to_a
    raise ArgumentError, "there is no background to remove" if versions.empty?

    ApplicationRecord.transaction do
      versions.each do |background|
        AuditEvent.record!(actor: actor, action: "destroy", target: background, changes_made: audited(background, nil),
                           reasoning: "Background deleted on the Profile page, with all #{versions.size} of its versions.")
        background.destroy!
      end
    end
    versions.size
  end

  def newest(profile) = profile&.backgrounds&.newest_first&.first

  # Its words, part by part: "312 words (what you're looking for 58, role preferences 120, not on the resume 134)".
  def said(background)
    parts = Background::PARTS.map { |part, about| "#{about[:label].sub("What I'm", "what you're").downcase_first} #{background.words(part)}" }
    "#{background.words} words (#{parts.join(', ')})"
  end

  # What changed, by each part's hash and words, and the whole's hash: never the text.
  def audited(before, after)
    changes = { "content_hash" => [ before&.content_hash, after&.content_hash ] }
    Background::PARTS.each_key do |part|
      was = [ before&.hash_of(part), before&.words(part) ]
      now = [ after&.hash_of(part), after&.words(part) ]
      next if was == now

      changes["#{part}_hash"] = [ was[0], now[0] ]
      changes["#{part}_words"] = [ was[1], now[1] ]
    end
    changes
  end

  private_class_method :audited
end
