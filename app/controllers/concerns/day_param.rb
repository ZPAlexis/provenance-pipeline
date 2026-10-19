# The day something happened, as the operator says it (an "on" field); today when not given.
module DayParam
  private

  def day = params[:on].present? ? Date.iso8601(params[:on]) : Date.current
end
