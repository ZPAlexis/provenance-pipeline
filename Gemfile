source "https://rubygems.org"

gem "rails", "~> 8.1.2"
gem "propshaft"
gem "pg"
gem "puma", ">= 5.0"
gem "importmap-rails"
gem "stimulus-rails"
gem "jbuilder"
gem "tzinfo-data", platforms: %i[ windows jruby ]
gem "solid_cache"
gem "solid_queue"
gem "solid_cable"
gem "bootsnap", require: false
gem "kamal", require: false
gem "thruster", require: false
gem "image_processing", "~> 1.2"
gem "turbo-rails"

# Bundled gem as of Ruby 3.4 — must be declared explicitly. Used by the CSV importer.
gem "csv"

group :development, :test do
  gem "debug", platforms: %i[ mri windows ], require: "debug/prelude"
  gem "bundler-audit", require: false
  gem "brakeman", require: false
  gem "rubocop-rails-omakase", require: false
  gem "rspec-rails", "~> 8.0.4"
  gem "factory_bot_rails"
  gem "faker"
end

group :development do
  gem "web-console"
end

group :test do
  gem "capybara"
  gem "selenium-webdriver"
end

gem "letter_opener_web", "~> 3.0", group: :development
