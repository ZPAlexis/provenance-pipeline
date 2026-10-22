module ProvenanceMcp
  module Tools
    # The applications, where each stands and what is written for it: where a client starts to pick one.
    class ListApplications < ReadTool
      tool_name "list_applications"
      title "The applications"
      description "The applications on record, open ones by default: each one's role, company, stage and since when, " \
                  "what is already written for it, and its id (what get_application_materials and the prompts take)."
      input_schema(properties: { closed: { type: "boolean", description: "Also list closed ones (accepted, rejected, withdrawn, no response)" } })

      class << self
        def answer(closed: false)
          applications = (closed ? Application.all : Application.open).includes(:company, :posting, :drafts, :resume_reviews)
                                                                      .order(:stage_changed_on)
          return ProvenanceMcp.text("No #{'open ' unless closed}application on record.") if applications.empty?

          ProvenanceMcp.text(applications.map { |application| line(application) })
        end

        private

        def line(application)
          role = application.posting
          drafts = (application.drafts.map { |draft| "#{draft.label.downcase}#{' (approved)' if draft.approved?}" } +
                    application.resume_reviews.map { "resume review" }).tally.map { |what, count| count > 1 ? "#{what} x#{count}" : what }
          "- #{Writing.label(application)}#{" (#{role.location})" if role.location}: " \
            "#{Application.stage_label(application.stage).downcase} since #{application.stage_changed_on} " \
            "(#{application.days_in_stage} #{'day'.pluralize(application.days_in_stage)}); " \
            "written: #{drafts.join(', ').presence || 'nothing yet'}; id #{application.id}"
        end
      end
    end
  end
end
