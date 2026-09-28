require_relative "boot"

require "rails"

# Only the frameworks this app uses. Action Mailer stays for mailer previews and
# a possible Stage 1.4 email digest. Dropped template leftovers: Active Storage,
# Action Cable, Action Mailbox, Action Text — and the test_unit railtie, since
# the suite is RSpec (a `bin/rails test` task would pass against nothing).
require "active_model/railtie"
require "active_job/railtie"
require "active_record/railtie"
require "action_controller/railtie"
require "action_mailer/railtie"
require "action_view/railtie"
# require "active_storage/engine"
# require "action_cable/engine"
# require "action_mailbox/engine"
# require "action_text/engine"
# require "rails/test_unit/railtie"

Bundler.require(*Rails.groups)

module ProvenancePipeline
  class Application < Rails::Application
    config.load_defaults 8.1
    config.autoload_lib(ignore: %w[assets tasks])

    config.generators do |g|
      g.orm :active_record, primary_key_type: :uuid
    end
  end
end
