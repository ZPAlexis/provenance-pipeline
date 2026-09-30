namespace :db do
  desc "Back up the database with pg_dump to a timestamped, owner-only file outside the repo"
  task backup: :environment do
    puts "Backed up to #{DatabaseBackup.call}"
  end
end
