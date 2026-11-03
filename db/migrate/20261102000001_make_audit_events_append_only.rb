# The audit log is append-only in the database itself (review pass R4): every UPDATE, DELETE or TRUNCATE of
# audit_events is refused by a trigger, behind the app's own check. Kept in schema.rb by the fx gem, so the
# test database, CI and a fresh setup carry it too.
class MakeAuditEventsAppendOnly < ActiveRecord::Migration[8.1]
  def change
    create_function :audit_events_append_only
    create_trigger :audit_events_append_only, on: :audit_events
    create_trigger :audit_events_no_truncate, on: :audit_events
  end
end
