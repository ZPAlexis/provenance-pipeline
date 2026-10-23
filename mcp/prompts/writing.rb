module ProvenanceMcp
  # The four kinds of writing about an application (2d), as prompts the operator picks in their client: each
  # carries the writing rules the in-app drafter keeps, and the application's materials, so the operator's own
  # Claude client writes on their subscription. Nothing is sent; saving it back comes with 2d step 3. The base
  # sits outside Prompts, so only the four below are served.
  class WritingPrompt < Prompt
    APPLICATION = MCP::Prompt::Argument.new(name: "application", title: "Application", required: true,
                                            description: "Its company and role (acme sales engineer), or its id")
    LANGUAGE = MCP::Prompt::Argument.new(name: "language", title: "Language",
                                         description: "Optional: the language to write in (by default the role's, or the resume's)")
    STRESS = MCP::Prompt::Argument.new(name: "stress", title: "Anything to stress",
                                       description: "Optional: what to put first, as long as the resume shows it")

    class << self
      def kind(value = nil) = value ? (@kind = value) : @kind

      # Unknown arguments a client sends are set aside.
      def compose(application:, language: nil, stress: nil, **)
        found = ProvenanceMcp::Lookup.application(application)
        [ ProvenanceMcp::Writing.instructions(kind, language: language, stress: stress),
          ProvenanceMcp::Writing.materials(found) ].join("\n\n---\n\n")
      end
    end
  end

  module Prompts
    class CoverLetter < WritingPrompt
      prompt_name "cover_letter"
      title "Cover letter"
      description "A cover letter for an application, written from your resume and the role's description, claiming only what the resume shows."
      arguments [ APPLICATION, LANGUAGE, STRESS ]
      kind "cover_letter"
    end

    class OutreachNote < WritingPrompt
      prompt_name "outreach_note"
      title "Outreach note"
      description "A short note to a recruiter or hiring manager about an application, with a subject line."
      arguments [ APPLICATION, LANGUAGE, STRESS ]
      kind "outreach_note"
    end

    class ResumeReview < WritingPrompt
      prompt_name "resume_review"
      title "Resume review"
      description "Your resume weighed against an application's role: strengths with the lines behind them, gaps, suggestions."
      arguments [ APPLICATION, LANGUAGE ]
      kind "resume_review"
    end

    class TailoredResume < WritingPrompt
      prompt_name "tailored_resume"
      title "Tailored resume"
      description "Your resume rewritten for an application's role: reordered, trimmed, reworded, never adding a fact."
      arguments [ APPLICATION, LANGUAGE, STRESS ]
      kind "tailored_resume"
    end
  end
end
