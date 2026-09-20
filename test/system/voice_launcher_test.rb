require "application_system_test_case"

class VoiceLauncherTest < ApplicationSystemTestCase
  test "voice launcher is inert on load and makes no session or tool requests" do
    visit products_path

    assert_selector "[data-voice-launcher][data-voice-state='idle']"
    assert_no_selector "elevenlabs-convai"
    assert_equal 0, voice_requests.length
    assert_selector "nav a[aria-current='page']", text: "Catalog"
  end

  test "product detail page also carries an inert voice launcher" do
    visit product_path("00001234")

    assert_selector "[data-voice-launcher][data-voice-state='idle']"
    assert_equal 0, voice_requests.length
  end

  test "explicit agreement authorizes connects and registers forwarding client tools" do
    visit products_path
    stub_voice_network(session: successful_session_response)

    click_button "Start voice shopping"
    assert_selector "[data-voice-launcher][data-voice-state='disclosure_required']"
    assert_text "Voice audio is processed by ElevenLabs, our voice provider."

    click_button "Agree & start"
    assert_selector "[data-voice-launcher][data-voice-state='connected']", wait: 5
    assert_selector "elevenlabs-convai", visible: :all
    assert_equal 1, voice_requests.count { |request| request.fetch("url") == "/voice/session" }

    call_result = page.evaluate_async_script(<<~JAVASCRIPT)
      var callback = arguments[0];
      var element = document.querySelector("elevenlabs-convai");
      element.dispatchEvent(new CustomEvent("elevenlabs-convai:call", { detail: { config: {} } }));
      window.__voiceLastCallConfig.clientTools.search_products({ query: "bins" }).then(function (result) {
        callback(result);
      });
    JAVASCRIPT

    assert_equal({ "ok" => true, "tool" => "search_products" }, call_result)
    tool_request = voice_requests.find { |request| request.fetch("url") == "/voice/tools/search_products" }
    assert tool_request, "expected a forwarded tool call"
    # The tool endpoint authorizes the AI grant, not the provider conversation
    # token. Sending the latter authenticated nothing and failed every call.
    assert_equal "Bearer voice-grant-token", tool_request.fetch("authorization")
    refute_includes tool_request.fetch("authorization"), "voice-conversation-token"
    expected_csrf = page.evaluate_script(<<~JAVASCRIPT)
      (function () {
        var meta = document.querySelector('meta[name="csrf-token"]');
        return (meta ? meta.getAttribute("content") : null) || "";
      })();
    JAVASCRIPT
    assert_equal expected_csrf, tool_request.fetch("csrf")
    assert_equal({ "query" => "bins" }, tool_request.fetch("body"))
  end

  test "a failing tool call surfaces an error result without breaking the page" do
    visit products_path
    stub_voice_network(session: successful_session_response, tool_status: 422, tool_error: "invalid_arguments")

    click_button "Start voice shopping"
    click_button "Agree & start"
    assert_selector "[data-voice-launcher][data-voice-state='connected']", wait: 5

    page.execute_script(<<~JAVASCRIPT)
      var launcher = document.querySelector("[data-voice-launcher]");
      var element = document.querySelector("elevenlabs-convai");
      element.dispatchEvent(new CustomEvent("elevenlabs-convai:call", { detail: { config: {} } }));
      window.__voiceLastCallConfig.clientTools.get_product_details({ id: "1" }).then(function (result) {
        launcher.setAttribute("data-voice-debug-tool-result", JSON.stringify(result));
      });
    JAVASCRIPT

    assert_selector "[data-voice-launcher][data-voice-debug-tool-result]", wait: 5
    call_result = JSON.parse(find("[data-voice-launcher]", visible: :all)["data-voice-debug-tool-result"])

    assert_equal({ "error" => "invalid_arguments" }, call_result)
    assert_selector "[data-voice-launcher][data-voice-state='connected']"
    assert_selector "nav a[aria-current='page']", text: "Catalog"
  end

  test "microphone denial falls back to text browsing without blocking the site" do
    visit products_path
    stub_voice_network(session: successful_session_response)
    deny_microphone_access

    click_button "Start voice shopping"
    click_button "Agree & start"

    assert_selector "[data-voice-launcher][data-voice-state='permission_denied']", wait: 5
    assert_text "Microphone access was denied."
    assert_selector "[data-voice-fallback]:not([hidden])"
    assert_no_selector "elevenlabs-convai"

    click_link "Catalog"
    assert_selector "h1", text: "Browse the sample catalog"
  end

  test "an authorization refusal surfaces the error state and text fallback" do
    visit products_path
    stub_voice_network(session_status: 503, session_error: "source_unavailable")

    click_button "Start voice shopping"
    click_button "Agree & start"

    assert_selector "[data-voice-launcher][data-voice-state='error']", wait: 5
    assert_selector "[data-voice-fallback]:not([hidden])"
    click_button "Continue browsing"
    assert_selector "[data-voice-launcher][data-voice-state='idle']"
  end

  test "an expired authorization is distinguished from a generic error" do
    visit products_path
    stub_voice_network(session_status: 401, session_error: "expired")

    click_button "Start voice shopping"
    click_button "Agree & start"

    assert_selector "[data-voice-launcher][data-voice-state='expired']", wait: 5
  end

  test "a failed provider script load degrades to the error state" do
    visit products_path
    stub_voice_network(session: successful_session_response, define_widget_element: false)
    page.execute_script("window.__voiceWidgetScriptSrcOverride = '/voice-widget-that-does-not-exist.js'")

    click_button "Start voice shopping"
    click_button "Agree & start"

    assert_selector "[data-voice-launcher][data-voice-state='error']", wait: 5
    assert_no_selector "elevenlabs-convai"
  end

  test "reconnecting after a disconnect tears down the previous widget before mounting a new one" do
    visit products_path
    stub_voice_network(session: successful_session_response)

    click_button "Start voice shopping"
    click_button "Agree & start"
    assert_selector "[data-voice-launcher][data-voice-state='connected']", wait: 5
    assert_selector "[data-voice-widget-mount] elevenlabs-convai", count: 1, visible: :all

    page.execute_script(<<~JAVASCRIPT)
      document.querySelector("elevenlabs-convai").dispatchEvent(new CustomEvent("elevenlabs-convai:disconnect"))
    JAVASCRIPT
    assert_selector "[data-voice-launcher][data-voice-state='disconnected']", wait: 5

    click_button "Try voice again"
    assert_selector "[data-voice-launcher][data-voice-state='connected']", wait: 5
    assert_selector "[data-voice-widget-mount] elevenlabs-convai", count: 1, visible: :all
    assert_equal 2, voice_requests.count { |request| request.fetch("url") == "/voice/session" }
  end

  private
    def successful_session_response
      {
        conversation_token: "voice-conversation-token",
        grant_token: "voice-grant-token",
        agent_id: "agent-123",
        expires_at: 1.hour.from_now.iso8601
      }
    end

    # Stubs window.fetch for the voice endpoints so tests make zero live
    # network calls, and pre-registers the "elevenlabs-convai" custom element
    # so the provider widget script itself is never requested.
    def stub_voice_network(session: nil, session_status: 200, session_error: nil, tool_status: 200, tool_error: nil, define_widget_element: true)
      session_body = session || { error: session_error }
      define_widget_element_js = define_widget_element
      page.execute_script(<<~JAVASCRIPT)
        (function () {
          window.__voiceRequests = [];
          if (!navigator.mediaDevices) {
            Object.defineProperty(navigator, "mediaDevices", { value: {}, configurable: true, writable: true });
          }
          if (!navigator.mediaDevices.getUserMedia) {
            navigator.mediaDevices.getUserMedia = function () {
              return Promise.resolve({ getTracks: function () { return []; } });
            };
          }
          if (#{define_widget_element_js} && !window.customElements.get("elevenlabs-convai")) {
            window.customElements.define("elevenlabs-convai", class extends HTMLElement {
              connectedCallback() {
                this.addEventListener("elevenlabs-convai:call", (event) => {
                  window.__voiceLastCallConfig = event.detail.config;
                });
                var element = this;
                setTimeout(function () {
                  element.dispatchEvent(new CustomEvent("elevenlabs-convai:call", { detail: { config: {} } }));
                }, 0);
              }
            });
          }

          var sessionBody = #{session_body.to_json};
          var sessionStatus = #{session_status};
          var toolStatus = #{tool_status};
          var toolError = #{tool_error.to_json};

          window.fetch = function (url, options) {
            options = options || {};
            if (url === "/voice/session") {
              window.__voiceRequests.push({ url: url, csrf: (options.headers || {})["X-CSRF-Token"] });
              return Promise.resolve({
                ok: sessionStatus >= 200 && sessionStatus < 300,
                status: sessionStatus,
                json: function () { return Promise.resolve(sessionBody); }
              });
            }
            if (url.indexOf("/voice/tools/") === 0) {
              var headers = options.headers || {};
              window.__voiceRequests.push({
                url: url,
                csrf: headers["X-CSRF-Token"],
                authorization: headers.Authorization,
                body: JSON.parse(options.body || "{}")
              });
              var body = toolStatus >= 200 && toolStatus < 300
                ? { ok: true, tool: url.split("/").pop() }
                : { error: toolError };
              return Promise.resolve({
                ok: toolStatus >= 200 && toolStatus < 300,
                status: toolStatus,
                json: function () { return Promise.resolve(body); }
              });
            }
            return Promise.reject(new Error("unexpected fetch: " + url));
          };
        })();
      JAVASCRIPT
    end

    def deny_microphone_access
      page.execute_script(<<~JAVASCRIPT)
        if (!navigator.mediaDevices) {
          Object.defineProperty(navigator, "mediaDevices", { value: {}, configurable: true, writable: true });
        }
        navigator.mediaDevices.getUserMedia = function () {
          return Promise.reject(new DOMException("Permission denied", "NotAllowedError"));
        };
      JAVASCRIPT
    end

    def voice_requests
      page.evaluate_script("window.__voiceRequests || []")
    end
end
