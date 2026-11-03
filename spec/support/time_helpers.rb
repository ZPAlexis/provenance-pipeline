RSpec.configure do |config|
  config.include ActiveSupport::Testing::TimeHelpers
end

# Each write a minute after the one before, as a person makes them (review pass R8). Written milliseconds apart, which
# of two versions is the newer, or the order of events, would rest on a clock WSL's host steps back now and then.
# From the start of today, so every write stays today. Every version of one kind goes through it, the first included:
# one written now would be later than those it writes.
module LaterHelper
  def later(&block)
    @clock = (@clock || Time.current.beginning_of_day) + 1.minute
    travel_to(@clock, &block)
  end
end

RSpec.configure { |config| config.include LaterHelper }
