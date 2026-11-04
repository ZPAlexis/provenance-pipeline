# Run using bin/ci
#
# Mirrors .github/workflows/ci.yml so a local run is a faithful preflight.
# Keep the two in step: a divergence here is how a red push gets through.

CI.run do
  step "Setup", "bin/setup --skip-server"

  step "Style: Ruby", "bin/rubocop"

  # A fresh advisory database first, as GitHub's runner has: the cached one let five flagged gems through.
  step "Security: Gem audit", "bin/bundler-audit check --update"
  step "Security: Importmap vulnerability audit", "bin/importmap audit"
  step "Security: Brakeman code analysis", "bin/brakeman --quiet --no-pager --exit-on-warn --exit-on-error"
  # Local only, the one step GitHub's workflow can't mirror: the target list it checks against is this machine's
  # record, which is private. No company on it is named in the repo or in a commit not yet pushed.
  step "Privacy: no company on the record named", "bin/rails privacy:names"

  # RSpec, not `bin/rails test` — this project has no minitest suite and the
  # test/ directory was removed. Running the wrong runner is worse than running
  # none: it passes against nothing and reports green.
  step "Tests: RSpec", "bundle exec rspec"

  # The Python verification worker, as the `verifier` CI job runs it.
  step "Verifier: Lint", "cd workers/verifier && uv run ruff check . && uv run ruff format --check ."
  step "Verifier: Tests", "cd workers/verifier && uv run pytest -q"

  # Optional: set a green GitHub commit status to unblock PR merge.
  # Requires the `gh` CLI and `gh extension install basecamp/gh-signoff`.
  # if success?
  #   step "Signoff: All systems go. Ready for merge and deploy.", "gh signoff"
  # else
  #   failure "Signoff: CI failed. Do not merge or deploy.", "Fix the issues and try again."
  # end
end
