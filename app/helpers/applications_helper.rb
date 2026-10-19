module ApplicationsHelper
  STAGE_TONES = { "offer" => "live", "accepted" => "live", "rejected" => "gone" }.freeze

  def stage_badge(stage) = tag.span(Application.stage_label(stage), class: [ "badge", STAGE_TONES.fetch(stage, "") ])

  def stage_options(selected = nil)
    options_for_select(Application::STAGES.map { |stage| [ Application.stage_label(stage), stage ] }, selected)
  end

  def activity_options(selected = "email") = options_for_select(Activity::KINDS.map { |kind| [ kind.humanize, kind ] }, selected)

  # The application's stages as a path, Salesforce-style: each open stage done, current, or still ahead,
  # then where it ends (accepted, or the outcome it closed at). Each links to the move form with that stage
  # picked, so a move is a click, a date, and a note.
  Step = Data.define(:stage, :label, :state)

  def stage_path(application, timeline)
    # Newest first, each move's stage then the one it left: a closed one closed from the latest open stage among them.
    reached = timeline.flat_map { |entry| [ entry.stage, entry.from ] }.compact
    last_open = application.open? ? application.stage : reached.find { |stage| Application::OPEN.include?(stage) }
    upto = Application::OPEN.index(last_open) || -1
    steps = Application::OPEN.each_with_index.map do |stage, index|
      state = if stage == application.stage then "current"
      elsif index < upto || (index == upto && !application.open?) then "done"
      else "ahead"
      end
      Step.new(stage: stage, label: Application.stage_label(stage), state: state)
    end
    ending = if application.stage == "accepted" then Step.new(stage: "accepted", label: "Accepted", state: "won")
    elsif application.open? then Step.new(stage: "accepted", label: "Accepted", state: "ahead")
    else Step.new(stage: application.stage, label: Application.stage_label(application.stage), state: "lost")
    end
    steps + [ ending ]
  end

  # How long it has been at its stage, in words.
  def in_stage(application)
    days = application.days_in_stage
    days.zero? ? "since today" : "for #{pluralize(days, 'day')}"
  end
end
