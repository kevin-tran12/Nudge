require "test_helper"

class SharedPrimitivesTest < ActionView::TestCase
  test "button renders an accessible link target" do
    render partial: "shared/button", locals: {
      label: "Browse with Nudge",
      href: "/",
      variant: :primary
    }

    assert_select "a[href='/'].min-h-11", text: "Browse with Nudge"
    assert_select "a[class*='focus-visible:']"
  end

  test "card renders a semantic heading and body" do
    render partial: "shared/card", locals: {
      title: "Clear choices",
      body: "See what fits and why.",
      eyebrow: "Shopping support"
    }

    assert_select "article"
    assert_select "h2", text: "Clear choices"
    assert_select "p", text: "See what fits and why."
  end

  test "badge and notice do not communicate state through color alone" do
    render partial: "shared/badge", locals: { label: "Ready", tone: :success }
    assert_select "span", text: "Ready"

    render partial: "shared/notice", locals: {
      title: "Something changed",
      message: "Review the latest information.",
      tone: :warning
    }
    assert_select "section[role='status'][aria-live='polite']"
    assert_select "h2", text: "Something changed"

    render partial: "shared/notice", locals: {
      title: "Action needed",
      message: "Please review the form.",
      tone: :danger
    }
    assert_select "section[role='alert'][aria-live='assertive']"
  end

  test "form field associates its label help and errors" do
    render partial: "shared/form_field", locals: {
      name: "shopping_need",
      label: "What do you need?",
      value: "",
      help: "Describe the result you want.",
      errors: [ "is too broad" ]
    }

    assert_select "label[for='shopping_need']", text: "What do you need?"
    assert_select "input#shopping_need[aria-invalid='true'][aria-describedby='shopping_need_help shopping_need_errors']"
    assert_select "#shopping_need_help", text: "Describe the result you want."
    assert_select "#shopping_need_errors[role='alert']", text: /is too broad/
  end

  test "status exposes updates without stealing focus" do
    render partial: "shared/status", locals: { message: "Results updated", busy: false }

    assert_select "div[role='status'][aria-live='polite'][aria-atomic='true']", text: "Results updated"
    assert_select "div[tabindex]", count: 0
  end
end
