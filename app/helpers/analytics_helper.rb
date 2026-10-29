module AnalyticsHelper
  # A number of days as measured: a median may fall between two days (3.5), a whole one shows whole.
  def days_measured(value)
    return tag.span("—", class: "muted") if value.nil?

    value.to_f == value.to_i ? value.to_i : value.to_f.round(1)
  end

  # A rate, or why there isn't one: too few to go on (Analytics::FLOOR).
  def rate_cell(rate, of)
    return "#{rate}%" if rate
    return tag.span("—", class: "muted") if of.to_i.zero?

    tag.span("too few to say", class: "muted", title: "#{of} to go on; a rate needs at least #{Analytics::FLOOR}")
  end
end
