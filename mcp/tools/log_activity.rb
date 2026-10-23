module ProvenanceMcp
  module Tools
    # The activity logger (2e): what the operator tells the client happened on an application, logged when they say
    # so, as agent:assistant, under a credential for this one call holding activities:write. It never moves the
    # application between stages: when an activity points to a later one, its answer says so, for the operator.
    class LogActivity < SaveTool
      tool_name "log_activity"
      title "Log an activity"
      description "Logs what happened on an application, only when the operator tells you it happened: an email, a call, " \
                  "an interview, an assessment, an offer, a note. Its kind, the day it happened (or is booked for), a " \
                  "one-line summary, and the contact it was with, if any. It never moves the application between stages: " \
                  "only the operator does, in the app."
      scopes "activities:write"
      # Activity::KINDS, written out: a tool's file loads before Rails boots (a spec keeps them in step).
      KINDS = %w[applied email call interview assessment offer note other].freeze

      # The stage an activity of each kind points to, when it is later than where the application stands.
      POINTS_TO = { "applied" => "applied", "interview" => "interviewing", "assessment" => "interviewing", "offer" => "offer" }.freeze

      input_schema(
        properties: {
          application: { type: "string", description: "Its id, or its company and role" },
          kind: { type: "string", enum: KINDS },
          summary: { type: "string", description: "What happened, in a line" },
          on: { type: "string", description: "The day it happened or is booked for, as YYYY-MM-DD; today when left out" },
          contact: { type: "string", description: "The contact it was with: their id or name" }
        },
        required: %w[application kind summary]
      )

      class << self
        def answer(application:, kind:, summary:, on: nil, contact: nil)
          found = Lookup.application(application)
          raise Refusal, "Say what happened: the summary is empty." if summary.to_s.strip.empty?

          day = day(on)
          with = Lookup.contact(found.company, contact) if contact.present?
          activity = Pipeline.log!(found, kind: kind, summary: summary, on: day, contact: with, actor: ASSISTANT, reasoning: "Logged through MCP.")
          ProvenanceMcp.text("Logged on #{Writing.label(found)}: #{activity.kind.humanize.downcase} on #{activity.occurred_on}" \
                             "#{" with #{with.name}" if with}: #{activity.summary}", stage_note(found, kind))
        end

        private

        def day(text)
          return Date.current if text.blank?

          Date.iso8601(text.to_s.strip)
        rescue Date::Error
          raise Refusal, "The day is a date like #{Date.current.iso8601}, not #{text.inspect}."
        end

        # When the activity points to a later stage: a word for the operator, who alone moves it.
        def stage_note(application, kind)
          stage = POINTS_TO[kind]
          return unless stage && application.open? && Application::OPEN.index(stage) > Application::OPEN.index(application.stage)

          "It points to #{Application.stage_label(stage)}; the application is at #{Application.stage_label(application.stage)}. " \
            "Only the operator moves it, on its page in the app (/applications/#{application.id})."
        end
      end
    end
  end
end
