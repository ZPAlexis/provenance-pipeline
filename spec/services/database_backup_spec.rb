require "rails_helper"

RSpec.describe DatabaseBackup do
  let(:dir) { Pathname.new(Dir.mktmpdir).join("backups") }
  let(:commands) { [] }
  let(:runner) { ->(env, *command) { commands << [ env, command ] } }

  after { FileUtils.remove_entry(dir.dirname) }

  it "dumps the current database with pg_dump to a timestamped file" do
    travel_to Time.utc(2026, 9, 30, 12, 0, 0) do
      path = described_class.call(dir: dir, runner: runner)

      database = ActiveRecord::Base.connection_db_config.database
      expect(path).to eq(dir.join("#{database}-20260930T120000Z.dump"))
      _env, command = commands.first
      expect(command).to start_with("pg_dump", "--format=custom", "--file", path.to_s)
      expect(command.last).to eq(database)
    end
  end

  # A dump is the whole private target list.
  it "keeps backups in a directory only the owner can read" do
    described_class.call(dir: dir, runner: runner)

    expect(File.stat(dir).mode & 0o777).to eq(0o700)
  end

  it "raises when pg_dump fails, so no write proceeds without a backup" do
    failing = ->(_env, *_command) { false }

    expect { described_class.call(dir: dir, runner: failing) }.to raise_error(described_class::Error, /pg_dump/)
  end
end
