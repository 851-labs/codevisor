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
      if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.codevisorBridge) {
        post("openUrl", url);
      } else {
        var target = new URL(String(url), window.location.href);
        if (target.protocol === "https:" || target.protocol === "http:") window.open(target.href, "_blank", "noopener");
      }
    },
    setTitle: function (title) {
      document.title = String(title);
      post("setTitle", title);
    }
  });
})();
