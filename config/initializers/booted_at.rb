# When this server process started. A check run left active by an earlier process
# was lost with it: development runs checks on an in-process queue, which does not
# survive a restart (CheckRun.abandon_stale!).
Rails.application.config.x.booted_at = Time.current
