/*
 * Voice launcher: inert-by-default voice shopping affordance.
 */
(function () {
  "use strict";

  var STATES = [
    "idle",
    "disclosure_required",
    "connecting",
    "connected",
    "listening",
    "speaking",
    "disconnected",
    "permission_denied",
    "expired",
    "error"
  ];

  var STATUS_COPY = {
    idle: "",
    disclosure_required: "Review the disclosure below before starting voice shopping.",
    connecting: "Connecting to voice shopping...",
    connected: "Voice shopping connected.",
    listening: "Listening...",
    speaking: "Nudge is speaking...",
    disconnected: "Voice shopping disconnected. You can reconnect or keep browsing without voice.",
    permission_denied: "Microphone access was denied. You can keep browsing and searching the catalog without voice.",
    expired: "Your voice session expired. Reconnect or keep browsing without voice.",
    error: "Voice shopping is unavailable right now. You can keep browsing and searching the catalog without voice."
  };

  var FALLBACK_STATES = { permission_denied: true, expired: true, error: true, disconnected: true };

  var STARTABLE_STATES = { idle: true, disconnected: true, permission_denied: true, expired: true, error: true };

  function csrfToken() {
    var meta = document.querySelector('meta[name="csrf-token"]');
    return meta ? meta.getAttribute("content") : null;
  }

  function setSectionVisible(section, visible) {
    if (!section) return;
    section.toggleAttribute("hidden", !visible);
    var controls = section.querySelectorAll("button, a[href], input, select, textarea");
    for (var index = 0; index < controls.length; index += 1) {
      var control = controls[index];
      if ("disabled" in control) control.disabled = !visible;
      if (visible) {
        control.removeAttribute("tabindex");
      } else {
        control.setAttribute("tabindex", "-1");
      }
    }
  }

  function VoiceLauncher(root) {
    this.root = root;
    this.state = "idle";
    this.grant = null;
    this.widgetEl = null;
    this.authorizing = false;

    this.startButton = root.querySelector('[data-voice-action="start"]');
    this.agreeButton = root.querySelector('[data-voice-action="agree"]');
    this.cancelButton = root.querySelector('[data-voice-action="cancel"]');
    this.retryButton = root.querySelector('[data-voice-action="retry"]');
    this.dismissButton = root.querySelector('[data-voice-action="dismiss-fallback"]');
    this.disclosure = root.querySelector("[data-voice-disclosure]");
    this.statusEl = root.querySelector("[data-voice-status]");
    this.fallback = root.querySelector("[data-voice-fallback]");
    this.widgetMount = root.querySelector("[data-voice-widget-mount]");

    this.bind();
    this.render();
  }

  VoiceLauncher.prototype.bind = function () {
    var self = this;
    if (this.startButton) {
      this.startButton.addEventListener("click", function () {
        self.setState("disclosure_required");
      });
    }
    if (this.cancelButton) {
      this.cancelButton.addEventListener("click", function () {
        self.setState("idle");
      });
    }
    if (this.agreeButton) {
      this.agreeButton.addEventListener("click", function () {
        self.authorize();
      });
    }
    if (this.retryButton) {
      this.retryButton.addEventListener("click", function () {
        self.reconnect();
      });
    }
    if (this.dismissButton) {
      this.dismissButton.addEventListener("click", function () {
        self.setState("idle");
      });
    }
  };

  VoiceLauncher.prototype.setState = function (next) {
    if (STATES.indexOf(next) === -1) return;
    this.state = next;
    this.render();
  };

  VoiceLauncher.prototype.render = function () {
    var state = this.state;
    this.root.setAttribute("data-voice-state", state);

    setSectionVisible(this.disclosure, state === "disclosure_required");
    setSectionVisible(this.fallback, !!FALLBACK_STATES[state]);

    var message = STATUS_COPY[state] || "";
    if (this.statusEl) {
      this.statusEl.textContent = message;
      this.statusEl.toggleAttribute("hidden", message === "");
      this.statusEl.setAttribute("aria-busy", state === "connecting" ? "true" : "false");
    }

    if (this.startButton) {
      this.startButton.disabled = !STARTABLE_STATES[state];
    }
  };

  VoiceLauncher.prototype.authorize = function () {
    if (this.authorizing) return;
    this.authorizing = true;
    this.setState("connecting");

    var self = this;
    fetch("/voice/session", {
      method: "POST",
      credentials: "same-origin",
      headers: {
        Accept: "application/json",
        "X-CSRF-Token": csrfToken() || ""
      }
    })
      .then(function (response) {
        return response
          .json()
          .catch(function () {
            return {};
          })
          .then(function (body) {
            return { response: response, body: body };
          });
      })
      .then(function (result) {
        var response = result.response;
        var body = result.body || {};

        if (!response.ok) {
          self.setState(response.status === 401 || body.error === "expired" ? "expired" : "error");
          return null;
        }
        if (!body.conversation_token || !body.agent_id) {
          self.setState("error");
          return null;
        }

        self.grant = {
          conversationToken: body.conversation_token,
          grantToken: body.grant_token,
          agentId: body.agent_id,
          expiresAt: body.expires_at
        };
        return self.connect();
      })
      .catch(function () {
        self.setState("error");
      })
      .finally(function () {
        self.authorizing = false;
      });
  };

  VoiceLauncher.prototype.reconnect = function () {
    if (typeof ElevenLabsAdapter !== "undefined" && this.widgetMount) {
      ElevenLabsAdapter.unmount(this.widgetMount);
    }
    this.widgetEl = null;
    this.grant = null;
    this.authorize();
  };

  VoiceLauncher.prototype.connect = function () {
    var self = this;

    if (!this.grant) {
      this.setState("error");
      return Promise.resolve();
    }

    if (!(navigator.mediaDevices && navigator.mediaDevices.getUserMedia)) {
      this.setState("error");
      return Promise.resolve();
    }

    return navigator.mediaDevices
      .getUserMedia({ audio: true })
      .then(function (stream) {
        stream.getTracks().forEach(function (track) {
          track.stop();
        });

        if (typeof ElevenLabsAdapter === "undefined") {
          self.setState("error");
          return null;
        }

        return ElevenLabsAdapter.mount({
          grant: self.grant,
          mountPoint: self.widgetMount,
          onCallStart: function () {
            self.setState("connected");
          },
          onModeChange: function (mode) {
            if (mode === "listening" || mode === "speaking") self.setState(mode);
          },
          onDisconnect: function (reason) {
            self.setState(reason === "error" ? "error" : "disconnected");
          }
        })
          .then(function (element) {
            self.widgetEl = element;
          })
          .catch(function () {
            self.setState("error");
          });
      })
      .catch(function () {
        self.setState("permission_denied");
      });
  };

  // ELEVENLABS-SPECIFIC: removable provider integration; do not place domain logic here.
  //
  // Everything from here to the matching end marker talks to the ElevenLabs
  // provider widget only. Deleting this block (and its usage above) must
  // leave catalog browsing and navigation working: VoiceLauncher degrades to
  // the error state and its text fallback when ElevenLabsAdapter is
  // undefined.
  function widgetScriptSrc() {
    // Test-only seam: a fixed source never reads live overrides, so this is
    // read fresh on every call rather than cached at module init.
    if (typeof window !== "undefined" && window.__voiceWidgetScriptSrcOverride) {
      return window.__voiceWidgetScriptSrcOverride;
    }
    return "https://unpkg.com/@elevenlabs/convai-widget-embed";
  }

  // Client tools the voice agent may invoke. Arguments are forwarded to
  // Rails as an opaque pass-through; the client neither validates nor
  // invents argument shapes, and never lets the agent select a user or
  // session - Rails derives identity from the session cookie/AI grant.
  var CLIENT_TOOL_NAMES = ["search_products", "get_product_details", "get_current_shopping_state"];

  function callServerTool(toolName, args, grant) {
    return fetch("/voice/tools/" + encodeURIComponent(toolName), {
      method: "POST",
      credentials: "same-origin",
      headers: {
        "Content-Type": "application/json",
        Accept: "application/json",
        "X-CSRF-Token": csrfToken() || "",
        Authorization: "Bearer " + grant.grantToken
      },
      body: JSON.stringify(args || {})
    })
      .then(function (response) {
        return response
          .json()
          .catch(function () {
            return {};
          })
          .then(function (body) {
            if (!response.ok) {
              return { error: (body && body.error) || "tool_call_failed" };
            }
            return body;
          });
      })
      .catch(function () {
        return { error: "tool_call_unavailable" };
      });
  }

  function buildClientTools(grant) {
    var tools = {};
    CLIENT_TOOL_NAMES.forEach(function (toolName) {
      tools[toolName] = function (parameters) {
        return callServerTool(toolName, parameters, grant);
      };
    });
    return tools;
  }

  function loadWidgetScript() {
    if (window.customElements && window.customElements.get("elevenlabs-convai")) {
      return Promise.resolve();
    }
    return new Promise(function (resolve, reject) {
      var script = document.createElement("script");
      script.src = widgetScriptSrc();
      script.async = true;
      script.onload = function () {
        resolve();
      };
      script.onerror = function () {
        reject(new Error("voice_widget_script_failed"));
      };
      document.head.appendChild(script);
    });
  }

  var ElevenLabsAdapter = {
    mount: function (options) {
      var grant = options.grant;
      var mountPoint = options.mountPoint;

      return loadWidgetScript().then(function () {
        mountPoint.replaceChildren();

        var element = document.createElement("elevenlabs-convai");
        element.setAttribute("agent-id", grant.agentId);
        element.setAttribute("conversation-token", grant.conversationToken);

        element.addEventListener("elevenlabs-convai:call", function (event) {
          if (event.detail && event.detail.config) {
            event.detail.config.clientTools = buildClientTools(grant);
          }
          if (options.onCallStart) options.onCallStart();
        });
        element.addEventListener("elevenlabs-convai:mode-change", function (event) {
          var mode = event.detail && event.detail.mode;
          if (options.onModeChange) options.onModeChange(mode);
        });
        element.addEventListener("elevenlabs-convai:disconnect", function () {
          if (options.onDisconnect) options.onDisconnect("disconnected");
        });
        element.addEventListener("elevenlabs-convai:error", function () {
          if (options.onDisconnect) options.onDisconnect("error");
        });

        mountPoint.appendChild(element);
        return element;
      });
    },
    unmount: function (mountPoint) {
      if (mountPoint) mountPoint.replaceChildren();
    }
  };
  // END ELEVENLABS-SPECIFIC

  function init() {
    var roots = document.querySelectorAll("[data-voice-launcher]");
    for (var index = 0; index < roots.length; index += 1) {
      if (!roots[index].__voiceLauncher) {
        roots[index].__voiceLauncher = new VoiceLauncher(roots[index]);
      }
    }
  }

  document.addEventListener("DOMContentLoaded", init);
  document.addEventListener("turbo:load", init);
})();
