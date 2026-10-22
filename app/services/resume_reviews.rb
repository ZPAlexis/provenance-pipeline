# Reviews of the resume against an application's role (Stage 2d): saved by the operator's own Claude client
# through MCP as agent:assistant, under the credential of that one call (resume_reviews:write), read against
# the resume version the client saw; deleted only by the operator. Advice, never sent. Each is audited by its
# counts and hashes, never its text: it quotes the resume.
module ResumeReviews
  module_function

  def save!(application, language:, resume_version:, strengths: [], gaps: [], suggestions: [], note: nil, reported_model: nil,
            actor: "agent:assistant")
    language = language.to_s.strip
    raise ArgumentError, "name the language it is written in, in a few words" if language.empty? || language.size > Drafts::MAX_LANGUAGE

    resume, description = WrittenFrom.sources!(application, resume_version)
    strengths, dropped = WrittenFrom.with_lines(resume, strengths, "point")
    suggestions, dropped_too = WrittenFrom.with_lines(resume, suggestions, "change")
    raise ArgumentError, "a review says something: its strengths, gaps, or suggestions" if strengths.empty? && suggestions.empty? && Array(gaps).empty?

    review = application.resume_reviews.create!(
      language: language, strengths: strengths, gaps: WrittenFrom.gaps(gaps), suggestions: suggestions, note: note.to_s.strip.presence,
      dropped_lines: dropped + dropped_too, resume: resume, resume_hash: resume.content_hash, role_description: description,
      description_hash: description.content_hash, written_by: actor, reported_model: WrittenFrom.reported(reported_model),
      run_id: "mcp:#{Authority.credential&.id}"
    )
    summary = summary(review)
    AuditEvent.record!(actor: actor, action: "create", target: review, reasoning: "Saved through MCP: #{summary}",
                       changes_made: facts(review).transform_values { |value| [ nil, value ] })
    [ review, summary ]
  end

  # The operator's deletion; its audit record keeps its counts and hashes.
  def delete!(review, actor: AuditEvent::OPERATOR)
    ApplicationRecord.transaction do
      AuditEvent.record!(actor: actor, action: "destroy", target: review, changes_made: facts(review).transform_values { |value| [ value, nil ] },
                         reasoning: "Resume review deleted on its application's page.")
      review.destroy!
    end
  end

  def summary(review)
    dropped = WrittenFrom.dropped(review.dropped_lines)
    "Resume review in #{review.language}: #{WrittenFrom.counted(review.strengths.size, 'strength')}, " \
      "#{WrittenFrom.counted(review.gaps.size, 'gap')}, #{WrittenFrom.counted(review.suggestions.size, 'suggestion')}#{dropped}."
  end

  # What a review's audit events say of it: its counts and hashes, never its text.
  def facts(review)
    { "language" => review.language, "strengths" => review.strengths.size, "gaps" => review.gaps.size,
      "suggestions" => review.suggestions.size, "resume_hash" => review.resume_hash, "description_hash" => review.description_hash,
      "written_by" => review.written_by }
  end

  private_class_method :facts
end
