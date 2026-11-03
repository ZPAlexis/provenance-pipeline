-- The audit log is append-only in the database itself (review pass R4), behind the app's own check
-- (Authority refuses an event changed or deleted, for everyone): a write that slips past the app, by bulk
-- update, raw SQL or a console, is refused here too.
CREATE OR REPLACE FUNCTION audit_events_append_only()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  RAISE EXCEPTION 'the audit log is append-only: % on audit_events refused', TG_OP
    USING HINT = 'An event is never changed or deleted; record a new one.';
END;
$$;
