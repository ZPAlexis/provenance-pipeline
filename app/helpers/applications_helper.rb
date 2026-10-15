module ApplicationsHelper
  STAGE_TONES = { "offer" => "live", "accepted" => "live", "rejected" => "gone" }.freeze

  def stage_badge(stage) = tag.span(Application.stage_label(stage), class: [ "badge", STAGE_TONES.fetch(stage, "") ])

  def stage_options(selected = nil)
    options_for_select(Application::STAGES.map { |stage| [ Application.stage_label(stage), stage ] }, selected)
  end

  def activity_options = options_for_select(Activity::KINDS.map { |kind| [ kind.humanize, kind ] }, "email")

  # How long it has been at its stage, in words.
  def in_stage(application)
    days = application.days_in_stage
    days.zero? ? "since today" : "for #{pluralize(days, 'day')}"
  end
end
