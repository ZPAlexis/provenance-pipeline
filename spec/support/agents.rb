# Agent services write only under a credential (1.3): specs issue one as a run does.
module AgentHelpers
  # Runs the block as `actor`, under a credential with every scope its agent may hold (or `scopes`).
  def as_agent(actor, scopes: Authority::AGENTS.fetch(actor)[:scopes], &block)
    Authority.run(actor, scopes: scopes, purpose: "spec", &block)
  end

  # An agent service called as a run calls it: each call under a fresh credential for `actor`.
  def acting(actor, &build) = ActingService.new(actor, build)

  class ActingService
    def initialize(actor, build)
      @actor = actor
      @build = build
    end

    def method_missing(name, *args, **options, &block)
      Authority.run(@actor, scopes: Authority::AGENTS.fetch(@actor)[:scopes], purpose: "spec") do
        @build.call.public_send(name, *args, **options, &block)
      end
    end

    def respond_to_missing?(*) = true
  end
end

RSpec.configure { |config| config.include AgentHelpers }
