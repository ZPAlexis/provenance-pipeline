# Who is writing right now, for Authority's check: an agent's credential, a
# system grant, or nobody (the operator). Reset around every request and job.
class Current < ActiveSupport::CurrentAttributes
  attribute :principal, :unchecked
end
