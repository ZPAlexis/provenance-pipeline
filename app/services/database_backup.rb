# A pg_dump of the database to a timestamped file outside the repo.
#
# From Stage 1.2b the database holds writes that cannot be regenerated from
# source (resolutions, and later verdicts), so re-seeding is no longer a
# recovery path. Every verifier batch that writes runs this first and stops if
# it fails.
class DatabaseBackup
  DIR = Pathname.new(Dir.home).join(".local/share/provenance-pipeline/backups")

  class Error < StandardError; end

  # For checks the operator starts from the pages: a backup at most once a day,
  # so a day of one-role checks costs one dump, not one per click. Every verdict
  # they write is audited and can be undone; a batch from rake backs up each time.
  def self.daily(dir: DIR, runner: ->(env, *command) { system(env, *command) })
    latest = Dir.glob(Pathname.new(dir).join("*.dump").to_s).max_by { |path| File.mtime(path) }
    return Pathname.new(latest) if latest && File.mtime(latest) > 1.day.ago

    call(dir: dir, runner: runner)
  end

  def self.call(dir: DIR, runner: ->(env, *command) { system(env, *command) })
    config = ActiveRecord::Base.connection_db_config.configuration_hash
    database = config.fetch(:database)

    # A dump is the whole private target list: owner-only.
    FileUtils.mkdir_p(dir, mode: 0o700)
    File.chmod(0o700, dir)
    path = Pathname.new(dir).join("#{database}-#{Time.current.utc.strftime('%Y%m%dT%H%M%SZ')}.dump")

    env = config[:password] ? { "PGPASSWORD" => config[:password].to_s } : {}
    command = [ "pg_dump", "--format=custom", "--file", path.to_s,
                *([ "--host", config[:host].to_s ] if config[:host]),
                *([ "--port", config[:port].to_s ] if config[:port]),
                *([ "--username", config[:username].to_s ] if config[:username]),
                database ]
    runner.call(env, *command) or raise Error, "pg_dump failed; nothing was written"

    path
  end
end
