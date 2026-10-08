module ProfilesHelper
  WORK_MODE_LABELS = { "remote" => "Remote", "hybrid" => "Hybrid", "onsite" => "On-site" }.freeze
  LEVEL_LABELS = {
    "entry" => "Entry / junior", "senior" => "Senior / staff / principal", "lead" => "Lead",
    "director" => "Director / head", "executive" => "VP / C-level"
  }.freeze
  FIT_NOTE_LABELS = {
    "work_mode_not_stated" => "Work mode not stated", "place_not_stated" => "No place stated",
    "level_not_stated" => "Level not stated"
  }.freeze
  RULED_OUT_LABELS = {
    "excluded" => "An excluded word", "level" => "Level", "place" => "Place", "work_mode" => "Work mode"
  }.freeze

  def work_mode_options = SearchProfile::WORK_MODES.map { |mode| [ mode, WORK_MODE_LABELS.fetch(mode) ] }
  def level_options = SearchProfile::LEVELS.map { |level| [ level, LEVEL_LABELS.fetch(level) ] }

  def fit_note_label(note) = FIT_NOTE_LABELS.fetch(note, note.to_s.humanize)
  def fit_notes(notes) = safe_join(notes.map { |note| tag.span(fit_note_label(note), class: "badge unsure") }, " ")

  def ruled_out_label(rule) = RULED_OUT_LABELS.fetch(rule, rule.to_s.humanize)
  # In the order the worker weighs the rules.
  def ruled_out_order(rule) = RULED_OUT_LABELS.keys.index(rule) || RULED_OUT_LABELS.size

  def work_mode_label(mode) = WORK_MODE_LABELS.fetch(mode) { tag.span("Not stated", class: "muted") }
end
