# A pg_dump of the database to a timestamped file outside the repo.
#
# From Stage 1.2b the database holds writes that cannot be regenerated from
# source (resolutions, and later verdicts), so re-seeding is no longer a
# recovery path. Every verifier batch that writes runs this first and stops if
# it fails.
class DatabaseBackup
  DIR = Pathname.new(Dir.home).join(".local/share/provenance-pipeline/backups")

  class Error < StandardError; end

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
