source "https://rubygems.org"

gem "rails", "~> 8.1.2"
gem "propshaft"
gem "pg"
gem "puma", ">= 5.0"
gem "importmap-rails"
gem "stimulus-rails"
gem "tzinfo-data", platforms: %i[ windows jruby ]
gem "solid_cache"
gem "solid_queue"
gem "bootsnap", require: false
gem "turbo-rails"
# The MCP server (mcp/, Stage 2d) requires it itself: the app never loads it.
gem "mcp", require: false

# Bundled gem as of Ruby 3.4 — must be declared explicitly. Used by the CSV importer.
gem "csv"

# Database functions and triggers in migrations and schema.rb (review pass R4): the audit log is append-only in the
# database itself, and schema.rb rebuilds that wherever the schema is loaded (the test database, CI, a fresh setup).
gem "fx"

group :development, :test do
  gem "debug", platforms: %i[ mri windows ], require: "debug/prelude"
  gem "bundler-audit", require: false
  gem "brakeman", require: false
  gem "rubocop-rails-omakase", require: false
  # 8.x is the line that supports Rails 8 (6.1 targeted Rails 7.1).
  gem "rspec-rails", "~> 8.0"
  gem "factory_bot_rails"
  gem "faker"
end

group :development do
  gem "web-console"
end

gem "letter_opener_web", "~> 3.0", group: :development
