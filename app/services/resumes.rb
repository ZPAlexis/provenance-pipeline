# The operator's resume (Stage 2b): kept with the search profile, version by
# version, and removed only as a whole. Audited as the operator's, by each
# version's size and hash: the log never copies the text. No agent may write it
# (no scope allows it).
module Resumes
  MAX_CHARS = 50_000

  module_function

  # Keeps `text` as the resume's newest version; nil when it is the same text as now.
  def keep!(profile, text:, actor: AuditEvent::OPERATOR)
    text = text.to_s.gsub("\r\n", "\n").strip
    raise ArgumentError, "paste the resume's text first" if text.empty?
    raise ArgumentError, "a resume of over #{MAX_CHARS} characters is more than a resume" if text.size > MAX_CHARS

    current = profile.resumes.newest_first.first
    return if current&.content_hash == Resume.digest(text)

    ApplicationRecord.transaction do
      resume = profile.resumes.create!(text: text, content_hash: Resume.digest(text))
      AuditEvent.record!(
        actor: actor, action: "create", target: resume,
        changes_made: { "content_hash" => [ current&.content_hash, resume.content_hash ], "words" => [ current&.words, resume.words ] },
        reasoning: "Resume #{current ? 'changed' : 'saved'} on the Profile page: #{resume.words} words."
      )
      resume
    end
  end

  # Removes every version: the resume is gone from the record, its audit events naming only sizes and hashes.
  def remove!(profile, actor: AuditEvent::OPERATOR)
    versions = profile.resumes.to_a
    raise ArgumentError, "there is no resume to remove" if versions.empty?

    ApplicationRecord.transaction do
      versions.each do |resume|
        AuditEvent.record!(actor: actor, action: "destroy", target: resume,
                           changes_made: { "content_hash" => [ resume.content_hash, nil ], "words" => [ resume.words, nil ] },
                           reasoning: "Resume deleted on the Profile page, with all #{versions.size} of its versions.")
        resume.destroy!
      end
    end
    versions.size
  end
end
