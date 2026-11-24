# The lists' default order (4e): what you are applying to first, the furthest along first; then what has no application;
# then what has a closed one. Within each, the best fit first, then (the Companies page) the most roles tracked, then
# the most recently checked. Shared by the Roles and Companies pages.
module ListOrder
  module_function

  # Where an application puts its role or company: [group, within it], smaller first.
  def application_rank(application)
    return [ 1, 0 ] unless application
    return [ 2, 0 ] unless application.open?

    [ 0, -Application::OPEN.index(application.stage) ]
  end

  # `records` in that order, each given by `keys` as [application, fit score or nil, *more keys, last checked or nil],
  # the more keys larger first; ties keep the order they came in.
  def sort(records, &keys)
    records.each_with_index.sort_by do |record, index|
      application, fit, *more, checked = keys.call(record)
      [ *application_rank(application), -(fit || -1), *more.map { |key| -key.to_i }, -checked.to_i, index ]
    end.map(&:first)
  end
end
