require_relative "boot"

require "rails/all"

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
