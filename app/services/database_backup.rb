# A pg_dump of the database to a timestamped file outside the repo.
#
# From Stage 1.2b the database holds writes that cannot be regenerated from
# source (resolutions, and later verdicts), so re-seeding is no longer a
# recovery path. Every verifier batch that writes runs this first and stops if
# it fails.
#
# Each new dump prunes the folder (the newest few, and the newest of each week
# for a year) and, when a second folder is named, is copied there too: on
# another disk, so losing the database's disk does not lose its backups.
class DatabaseBackup
  DIR = Pathname.new(Dir.home).join(".local/share/provenance-pipeline/backups")
  # One line naming a folder for a copy of each new dump, on another disk. Kept
  # outside the repo, like the API key: it is one machine's layout. No file, no copy.
  MIRROR_FILE = Pathname.new(Dir.home).join(".config/provenance-pipeline/backup_mirror")
  KEEP_LATEST = 10 # the newest dumps, whatever their age: the "undo a bad batch" layer
  KEEP_WEEKS = 52 # and the newest dump of each week, for a year
  STAMP = "%Y%m%dT%H%M%SZ" # in each dump's name, UTC: its time, whatever copying does to the file's own

  class Error < StandardError; end

  # For checks the operator starts from the pages: a backup at most once a day,
  # so a day of one-role checks costs one dump, not one per click. Every verdict
  # they write is audited and can be undone; a batch from rake backs up each time.
  def self.daily(dir: DIR, **options)
    newest = dumps(dir).first
    return newest.last if newest && newest.first > 1.day.ago

    call(dir: dir, **options)
  end

  def self.call(dir: DIR, mirror: mirror_dir, runner: ->(env, *command) { system(env, *command) },
                report: ->(line) { puts line })
    config = ActiveRecord::Base.connection_db_config.configuration_hash
    database = config.fetch(:database)

    # A dump is the whole private target list: owner-only.
    FileUtils.mkdir_p(dir, mode: 0o700)
    File.chmod(0o700, dir)
    path = Pathname.new(dir).join("#{database}-#{Time.current.utc.strftime(STAMP)}.dump")

    env = config[:password] ? { "PGPASSWORD" => config[:password].to_s } : {}
    command = [ "pg_dump", "--format=custom", "--file", path.to_s,
                *([ "--host", config[:host].to_s ] if config[:host]),
                *([ "--port", config[:port].to_s ] if config[:port]),
                *([ "--username", config[:username].to_s ] if config[:username]),
                database ]
    runner.call(env, *command) or raise Error, "pg_dump failed; nothing was written"

    # Only once the new dump exists does anything old go.
    kept, removed = prune!(dir)
    report.call("Backups kept: #{kept}, removed: #{removed}.")
    copy(path, to: mirror, report: report) if mirror
    path
  end

  # This database's dumps in a folder, newest first, as [time, path]. Their time
  # is read from the name; a file named any other way is not one of them.
  def self.dumps(dir, database: ActiveRecord::Base.connection_db_config.database)
    return [] unless Dir.exist?(dir)

    pattern = /\A#{Regexp.escape(database)}-(\d{8}T\d{6}Z)\.dump\z/
    Dir.children(dir).filter_map do |name|
      stamp = name[pattern, 1] or next
      time = ActiveSupport::TimeZone["UTC"].strptime(stamp, STAMP)
      [ time, Pathname.new(dir).join(name) ]
    rescue ArgumentError
      nil
    end.sort_by(&:first).reverse
  end

  # Keeps the newest KEEP_LATEST dumps and the newest dump of each ISO week of the
  # last KEEP_WEEKS weeks; removes this database's other dumps. Returns [kept, removed].
  def self.prune!(dir, now: Time.current)
    all = dumps(dir)
    weekly = all.select { |time, _| time > now - KEEP_WEEKS.weeks }
                .group_by { |time, _| [ time.to_date.cwyear, time.to_date.cweek ] }.values.map(&:first)
    keep = (all.first(KEEP_LATEST) + weekly).uniq
    (all - keep).each { |_, path| File.delete(path) }
    [ keep.size, all.size - keep.size ]
  end

  # A copy on another disk, pruned the same way. A failed copy is said, never
  # raised: the dump on this disk exists, and the batch it protects can go on.
  def self.copy(path, to:, report:)
    FileUtils.mkdir_p(to)
    FileUtils.cp(path, to)
    kept, removed = prune!(to)
    report.call("Copied to #{to} (kept there: #{kept}, removed: #{removed}).")
  rescue SystemCallError => e
    report.call("Could not copy the backup to #{to}: #{e.message}")
  end

  def self.mirror_dir
    MIRROR_FILE.read.strip.presence if MIRROR_FILE.exist?
  end
end
