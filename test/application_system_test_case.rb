require "test_helper"

class ApplicationSystemTestCase < ActionDispatch::SystemTestCase
  driven_by :selenium,
    using: :headless_chrome,
    screen_size: [ 1280, 900 ],
    options: {
      browser: :remote,
      url: ENV.fetch("SELENIUM_URL")
    }

  Capybara.run_server = false
  Capybara.app_host = ENV.fetch("CAPYBARA_APP_HOST")
  Capybara.save_path = Rails.root.join("tmp/screenshots")
end
