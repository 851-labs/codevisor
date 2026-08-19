// Codevisor plugin bridge v1 (frozen surface):
//   window.codevisor.getContext() -> { workspaceId, cwd, paneId, themeMode }
//   window.codevisor.openUrl(url)
//   window.codevisor.setTitle(title)
//   :root --codevisor-* CSS custom properties
//   "codevisor:themechange" event on window (detail: { themeMode })
// Injected by the host at document start; everything else is bridge v2.
(function () {
  "use strict";
  if (window.codevisor) {
    return;
  }
  var state = window.__codevisorBridgeState || {};
  function post(type, value) {
    try {
      window.webkit.messageHandlers.codevisorBridge.postMessage({
        type: type,
        value: String(value == null ? "" : value)
      });
    } catch (error) {
      // Outside a Codevisor webview the bridge is inert.
    }
  }
  window.codevisor = Object.freeze({
    getContext: function () {
      var context = (window.__codevisorBridgeState || state).context || {};
      return {
        workspaceId: context.workspaceId || null,
        cwd: context.cwd || null,
        paneId: context.paneId || null,
        themeMode: context.themeMode || "light"
      };
    },
    openUrl: function (url) {
      post("openUrl", url);
    },
    setTitle: function (title) {
      post("setTitle", title);
    }
  });
})();
