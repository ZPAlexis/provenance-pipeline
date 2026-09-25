# Run using bin/ci
#
# Mirrors .github/workflows/ci.yml so a local run is a faithful preflight.
# Keep the two in step: a divergence here is how a red push gets through.

CI.run do
  step "Setup", "bin/setup --skip-server"

  step "Style: Ruby", "bin/rubocop"

  step "Security: Gem audit", "bin/bundler-audit"
  step "Security: Importmap vulnerability audit", "bin/importmap audit"
  step "Security: Brakeman code analysis", "bin/brakeman --quiet --no-pager --exit-on-warn --exit-on-error"

  # RSpec, not `bin/rails test` — this project has no minitest suite and the
  # test/ directory was removed. Running the wrong runner is worse than running
  # none: it passes against nothing and reports green.
  step "Tests: RSpec", "bundle exec rspec"

  # Optional: set a green GitHub commit status to unblock PR merge.
  # Requires the `gh` CLI and `gh extension install basecamp/gh-signoff`.
  # if success?
  #   step "Signoff: All systems go. Ready for merge and deploy.", "gh signoff"
  # else
  #   failure "Signoff: CI failed. Do not merge or deploy.", "Fix the issues and try again."
  # end
end
