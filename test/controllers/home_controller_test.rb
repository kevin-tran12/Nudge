require "test_helper"

class HomeControllerTest < ActionDispatch::IntegrationTest
  test "renders the accessible public application shell" do
    get root_path

    assert_response :success
    assert_select "title", "Nudge"
    assert_select "a[href='#main-content']", text: /Skip to content/
    assert_select "header nav[aria-label='Primary navigation']"
    assert_select "main#main-content[tabindex='-1']"
    assert_select "footer"
    assert_select "h1", count: 1
  end

  test "uses mobile-safe responsive layout and accessible controls" do
    get root_path

    assert_select "main.min-w-0"
    assert_select ".grid.grid-cols-1"
    assert_select "a.min-h-11"
    assert_select "a[class*='focus-visible:']"
  end
end
