# Run using bin/ci

CI.run do
  step "Setup", "bin/setup --skip-server"

  step "Style: Ruby", "bin/rubocop"

  step "Security: Gem audit", "bin/bundler-audit"
  # No import map or importmap executable is installed yet. Add a JavaScript
  # dependency audit when client-side packages are introduced.
  step "Security: Brakeman code analysis", "bin/brakeman --quiet --no-pager --exit-on-warn --exit-on-error"
  step "Tests: Rails with coverage", "bin/test-all"
  step "Tests: Production boot", "env RAILS_ENV=production SECRET_KEY_BASE_DUMMY=1 bin/rails runner 'Rails.application.eager_load!'"
  step "Tests: Seeds", "env RAILS_ENV=test bin/rails db:seed:replant"

  # Browser E2E becomes a required staging gate after a real browser lane is
  # registered. bin/test-browser fails clearly while that lane is absent.

  # Optional: set a green GitHub commit status to unblock PR merge.
  # Requires the `gh` CLI and `gh extension install basecamp/gh-signoff`.
  # if success?
  #   step "Signoff: All systems go. Ready for merge and deploy.", "gh signoff"
  # else
  #   failure "Signoff: CI failed. Do not merge or deploy.", "Fix the issues and try again."
  # end
end
