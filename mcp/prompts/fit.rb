module ProvenanceMcp
  module Prompts
    # Finding roles that fit, by meaning, and weighing each against the resume (2f step 3), all from the operator's
    # own client on their subscription: the client names the titles a role like theirs goes by, judges what
    # find_roles lists, proposes what may fit, has the descriptions read, and weighs each by the fit rules.
    class FindRoles < Prompt
      prompt_name "find_roles"
      title "Find roles that fit"
      description "Roles on your watched companies' pages that fit you, found by meaning rather than your profile's exact " \
                  "words, suggested, and each weighed against your resume from its description."
      arguments [ MCP::Prompt::Argument.new(name: "focus", title: "Anything to look for",
                                            description: "Optional: a kind of role, a field, or a company to look at first") ]

      class << self
        def compose(focus: nil, **)
          profile = SearchProfile.current
          return "No search profile is saved yet: it is set on the Profile page in the app." unless profile

          [ <<~TEXT.strip, ("Look first for: #{focus.to_s.strip}" if focus.to_s.strip.present?), profile_text(profile) ].compact.join("\n\n")
            Find roles on my watched companies' careers pages that fit me, judged by meaning, and weigh each against my resume.
            1. Read my resume and my profile (get_roles_to_weigh shows the resume, with the fit rules; my profile is below).
               List the titles a role like mine goes by: my profile's, and other wordings of the same work, up to 20.
            2. Call find_roles with them. It lists roles not on record yet, as my companies' pages were last read.
            3. Judge from each title, place and level which may fit me; a shared word isn't a fit. Tell me which you would
               suggest and why, and suggest them with suggest_roles when I say so (each with why, in a sentence). The lists
               are as last read: it reads each role's own page first and suggests only those still up, with their
               descriptions. Tell me which were gone.
            4. Weigh each one suggested with get_roles_to_weigh by the fit rules, saving each with save_fit_score: its ATS
               fit from my resume alone, and, when my background is saved, its Background fit beside it.
            5. Give me what you weighed, best first by the ATS fit, with each score and why in a line, the Background fit
               beside it, and its company's fit where the company is reviewed: separate scores, never merged.
            Nothing here tracks a role or sends anything: I track the ones I want, in the app or by asking you.
          TEXT
        end

        def profile_text(profile)
          listed = ->(items) { items.presence&.join(", ") || "(any)" }
          Writing.fence("profile", [ "Titles they search for: #{listed.call(profile.titles)}",
                                     "Words they exclude: #{listed.call(profile.excluded_words)}",
                                     "Places they can work: #{listed.call(profile.places)}",
                                     "Work modes: #{listed.call(profile.work_modes)}",
                                     "Levels: #{listed.call(profile.levels)}" ].join("\n"))
        end
      end
    end

    # Weighing the roles already offered (tracked or suggested) that have no current score (2f step 3), or (4c) those
    # weighed before the background as it is now.
    class WeighRoles < Prompt
      prompt_name "weigh_roles"
      title "Weigh my roles"
      description "Your tracked and suggested roles with no current fit score, or those weighed before your background, " \
                  "weighed against your resume (the ATS fit) and your background (the Background fit) from their " \
                  "descriptions, a few at a time, each saved as it is weighed."
      arguments [ MCP::Prompt::Argument.new(name: "how_many", title: "How many",
                                            description: "Optional: how many roles to weigh this time (5 when left out)"),
                  MCP::Prompt::Argument.new(name: "before_background", title: "Before my background",
                                            description: "Optional: yes to weigh again the roles weighed before your background") ]

      class << self
        def compose(how_many: nil, before_background: nil, **)
          count = how_many.to_s.strip.match?(/\A\d+\z/) ? how_many.to_i.clamp(1, 50) : 5
          again = before_background.to_s.strip.downcase.match?(/\A(y|yes|true|1)\z/)
          <<~TEXT.strip
            Weigh #{count} of my roles #{again ? 'weighed before my background as it is now, again' : 'that have no current fit score'}, against my resume and my background.
            Call get_roles_to_weigh#{' with before_background' if again} (up to 10 at a time) and weigh each by the rules it gives, two
            ways: the ATS fit from my resume alone, and the Background fit with my background too, saving both with
            save_fit_score as you go. A role named there with no description read yet: read it with read_descriptions
            first. Then give me what you weighed, best first by the ATS fit, with each score and why in a line, the
            Background fit beside it, and its company's fit where the company is reviewed (separate scores, never merged).
            Nothing here tracks a role: I track the ones I want, in the app or by asking you.
          TEXT
        end
      end
    end
  end
end
