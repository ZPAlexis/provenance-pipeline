# Whether an API key is set decides whether every check is a free one (4f). The specs say which, whatever the machine
# running them holds (a key here, none on GitHub's runners): a key, unless a spec says there is none.
module ApiKeyHelpers
  def without_api_key = allow(Verifier::Worker).to(receive(:credential_set?).and_return(false))
end

RSpec.configure do |config|
  config.include ApiKeyHelpers
  config.before { allow(Verifier::Worker).to receive(:credential_set?).and_return(true) }
end
