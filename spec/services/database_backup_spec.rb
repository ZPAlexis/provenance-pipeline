require "rails_helper"

RSpec.describe DatabaseBackup do
  let(:root) { Pathname.new(Dir.mktmpdir) }
  let(:dir) { root.join("backups") }
  let(:commands) { [] }
  let(:lines) { [] }
  let(:report) { ->(line) { lines << line } }
  let(:database) { ActiveRecord::Base.connection_db_config.database }
  # Stands in for pg_dump: records the command and writes the file it names.
  let(:runner) do
    lambda do |env, *command|
      commands << [ env, command ]
      FileUtils.touch(command[command.index("--file") + 1])
    end
  end

  after { FileUtils.remove_entry(root) }

  # A dump file as pg_dump would have named it, at the given time.
  def dump_at(time, folder = dir, name: database)
    FileUtils.mkdir_p(folder)
    folder.join("#{name}-#{time.utc.strftime(DatabaseBackup::STAMP)}.dump").tap { |path| FileUtils.touch(path) }
  end

  def names(folder = dir) = Dir.children(folder).sort

  it "dumps the current database with pg_dump to a timestamped file" do
    travel_to Time.utc(2026, 9, 30, 12, 0, 0) do
      path = described_class.call(dir: dir, mirror: nil, runner: runner, report: report)

      expect(path).to eq(dir.join("#{database}-20260930T120000Z.dump"))
      _env, command = commands.first
      expect(command).to start_with("pg_dump", "--format=custom", "--file", path.to_s)
      expect(command.last).to eq(database)
    end
  end

  # A dump is the whole private target list.
  it "keeps backups in a directory only the owner can read" do
    described_class.call(dir: dir, mirror: nil, runner: runner, report: report)

    expect(File.stat(dir).mode & 0o777).to eq(0o700)
  end

  it "raises when pg_dump fails, so no write proceeds without a backup, and prunes nothing" do
    old = (1..12).map { |n| dump_at(n.days.ago) }

    expect { described_class.call(dir: dir, mirror: nil, runner: ->(*) { false }, report: report) }
      .to raise_error(described_class::Error, /pg_dump/)
    expect(old).to all(exist)
  end

  describe "retention" do
    it "keeps the ten newest dumps and the newest of each older week, for a year" do
      travel_to Time.utc(2026, 10, 7, 12) do
        recent = (0..9).map { |n| dump_at(n.hours.ago) } # the ten newest, all today
        earlier_today = dump_at(11.hours.ago)
        week_40 = [ dump_at(Time.utc(2026, 9, 30, 9)), dump_at(Time.utc(2026, 10, 2, 9)) ] # Mon 09-28 to Sun 10-04
        a_year_ago = dump_at(Time.utc(2025, 9, 1))

        kept, removed = described_class.prune!(dir)

        expect(recent).to all(exist)
        expect(week_40.last).to exist # that week's newest
        expect([ week_40.first, earlier_today, a_year_ago ]).to all(satisfy { |path| !path.exist? })
        expect([ kept, removed ]).to eq([ 11, 3 ])
      end
    end

    it "keeps a lone dump, and leaves alone any file that is not this database's dump" do
      only = dump_at(2.years.ago)
      others = [ dump_at(3.years.ago, name: "another_database"), dir.join("notes.txt"), dir.join("#{database}-latest.dump") ]
      others.drop(1).each { |path| FileUtils.touch(path) }

      expect(described_class.prune!(dir)).to eq([ 1, 0 ])
      expect([ only, *others ]).to all(exist)
    end

    it "prunes after each new dump and says what it kept and removed" do
      (1..12).each { |n| dump_at(n.minutes.ago) }

      described_class.call(dir: dir, mirror: nil, runner: runner, report: report)

      expect(names.size).to eq(10)
      expect(lines).to include("Backups kept: 10, removed: 3.")
    end
  end

  describe "a copy on another disk" do
    let(:mirror) { root.join("other_disk/provenance-pipeline") }

    it "copies each new dump there, and prunes it the same way" do
      (1..10).each { |n| dump_at(n.minutes.ago, mirror) }

      path = described_class.call(dir: dir, mirror: mirror.to_s, runner: runner, report: report)

      expect(mirror.join(path.basename)).to exist
      expect(names(mirror).size).to eq(10)
      expect(lines.last).to eq("Copied to #{mirror} (kept there: 10, removed: 1).")
    end

    it "says so when the copy fails, and keeps the dump on this disk" do
      blocked = root.join("a_file")
      FileUtils.touch(blocked)

      path = described_class.call(dir: dir, mirror: blocked.join("sub").to_s, runner: runner, report: report)

      expect(path).to exist
      expect(lines.last).to start_with("Could not copy the backup to #{blocked.join('sub')}")
    end
  end

  describe ".daily" do
    it "reuses a dump made in the last day, judged by its name, not the file's own time" do
      fresh = dump_at(2.hours.ago)
      expect(described_class.daily(dir: dir, mirror: nil, runner: ->(*) { raise "no new dump expected" }, report: report)).to eq(fresh)

      FileUtils.rm(fresh)
      stale = dump_at(2.days.ago)
      FileUtils.touch(stale) # a copy or restore makes the file look new; its name still says when it was made
      expect(described_class.daily(dir: dir, mirror: nil, runner: runner, report: report)).not_to eq(stale)
      expect(commands.size).to eq(1)
    end
  end
end
