import CryptoKit
import Foundation
import SwiftUI
import CodevisorTheming
import WebKit

#if canImport(AppKit)
  import AppKit
#else
  import UIKit
#endif

public struct WebPaneBridgeContext: Equatable, Sendable {
  public var workspaceId: String?
  public var cwd: String?
  public var paneId: String
  public var themeMode: String

  public init(workspaceId: String?, cwd: String?, paneId: String, themeMode: String) {
    self.workspaceId = workspaceId
    self.cwd = cwd
    self.paneId = paneId
    self.themeMode = themeMode
  }
}

public struct WebPaneThemeTokens: Equatable, Sendable {
  public var mode: String
  public var variables: [String: String]
  public var background: RGBA?

  public init(mode: String, variables: [String: String], background: RGBA? = nil) {
    self.mode = mode
    self.variables = variables
    self.background = background
  }

  public init(isDark: Bool) {
    self.init(
      mode: isDark ? "dark" : "light",
      variables: Self.systemVariables(isDark: isDark),
      background: isDark ? RGBA(r: 30, g: 30, b: 30) : RGBA(r: 255, g: 255, b: 255)
    )
  }

  private static let fontVariables: [String: String] = [
    "--codevisor-font-family": "-apple-system, BlinkMacSystemFont, 'Helvetica Neue', sans-serif",
    "--codevisor-font-family-mono": "ui-monospace, 'SF Mono', Menlo, monospace",
  ]

  private static func systemVariables(isDark: Bool) -> [String: String] {
    var variables = fontVariables
    variables["--codevisor-bg"] = isDark ? "#1e1e1e" : "#ffffff"
    variables["--codevisor-bg-elevated"] = isDark ? "#2a2a2a" : "#f5f5f5"
    variables["--codevisor-fg"] = isDark ? "#f5f5f7" : "#1d1d1f"
    variables["--codevisor-fg-secondary"] =
      isDark ? "rgba(255, 255, 255, 0.55)" : "rgba(0, 0, 0, 0.55)"
    variables["--codevisor-fg-tertiary"] =
      isDark ? "rgba(255, 255, 255, 0.35)" : "rgba(0, 0, 0, 0.35)"
    variables["--codevisor-border"] =
      isDark ? "rgba(255, 255, 255, 0.2)" : "rgba(0, 0, 0, 0.2)"
    variables["--codevisor-separator"] =
      isDark ? "rgba(255, 255, 255, 0.14)" : "rgba(0, 0, 0, 0.12)"
    variables["--codevisor-accent"] = isDark ? "#0a84ff" : "#007aff"
    variables["--codevisor-status-ok"] = isDark ? "#34d399" : "#047857"
    variables["--codevisor-status-warn"] = isDark ? "#f59e0b" : "#b45309"
    variables["--codevisor-status-error"] = isDark ? "#fb7185" : "#be123c"
    variables["--codevisor-diff-added"] = isDark ? "#5ecc71" : "#0dbe4e"
    variables["--codevisor-diff-removed"] = isDark ? "#ff6762" : "#ff2e3f"
    variables["--codevisor-diff-added-bg"] =
      isDark ? "rgba(94, 204, 113, 0.16)" : "rgba(13, 190, 78, 0.12)"
    variables["--codevisor-diff-removed-bg"] =
      isDark ? "rgba(255, 103, 98, 0.16)" : "rgba(255, 46, 63, 0.12)"
    return variables
  }

}

private struct WebPaneOrigin: Equatable {
  var scheme: String
  var host: String
  var port: Int

  init?(url: URL) {
    guard let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased()
    else { return nil }
    self.scheme = scheme
    self.host = host
    self.port = url.port ?? (scheme == "https" ? 443 : scheme == "http" ? 80 : -1)
  }
}

private final class WebPaneMessageProxy: NSObject, WKScriptMessageHandler {
  weak var controller: WebPaneController?

  init(controller: WebPaneController) {
    self.controller = controller
  }

  func userContentController(
    _ userContentController: WKUserContentController,
    didReceive message: WKScriptMessage
  ) {
    controller?.handleBridgeMessage(message.body)
  }
}

@MainActor
public final class WebPaneController: NSObject {
  private static let bridgeMessageName = "codevisorBridge"

  private static let bridgeScriptSource: String? = {
    guard let url = Bundle.module.url(forResource: "plugin-bridge", withExtension: "js")
    else { return nil }
    return try? String(contentsOf: url, encoding: .utf8)
  }()

  public let webView: WKWebView
  public var onSetTitle: ((String) -> Void)?
  public var onNavigationFailed: ((String) -> Void)?
  public var onConnectionFailure: ((any Error) -> Void)?
  private var mainFrameMethod: String?
  public var onNavigationFinished: (() -> Void)?

  private var context: WebPaneBridgeContext
  private var theme: WebPaneThemeTokens
  private var allowedOrigin: WebPaneOrigin?

  public static func pluginDataStoreIdentifier(for pluginId: String) -> UUID {
    let digest = SHA256.hash(data: Data(pluginId.utf8))
    let bytes = Array(digest.prefix(16))
    return NSUUID(uuidBytes: bytes) as UUID
  }

  public init(
    context: WebPaneBridgeContext,
    theme: WebPaneThemeTokens,
    dataStoreIdentifier: UUID? = nil
  ) {
    self.context = context
    self.theme = theme
    let configuration = WKWebViewConfiguration()
    if let dataStoreIdentifier {
      configuration.websiteDataStore = WKWebsiteDataStore(forIdentifier: dataStoreIdentifier)
    }
    self.webView = WKWebView(frame: .zero, configuration: configuration)
    super.init()
    webView.navigationDelegate = self
    webView.uiDelegate = self
    #if DEBUG
      webView.isInspectable = true
    #endif
    #if os(macOS)
      configuration.userContentController.add(
        WebPaneMessageProxy(controller: self),
        name: Self.bridgeMessageName
      )
    #endif
    applyBackground()
    installUserScripts()
  }

  public func load(_ url: URL) {
    allowedOrigin = WebPaneOrigin(url: url)
    webView.load(URLRequest(url: url))
  }

  public func stopLoading() {
    webView.stopLoading()
  }

  public func applyTheme(_ tokens: WebPaneThemeTokens) {
    guard tokens != theme else { return }
    theme = tokens
    context.themeMode = tokens.mode
    applyBackground()
    installUserScripts()
    webView.evaluateJavaScript(themeUpdateScript()) { _, _ in }
  }

  fileprivate func handleBridgeMessage(_ body: Any) {
    guard let payload = body as? [String: Any],
      let type = payload["type"] as? String
    else { return }
    let value = payload["value"] as? String ?? ""
    switch type {
    case "openUrl":
      guard let url = URL(string: value), let external = Self.externalURL(url)
      else { return }
      openExternally(external)
    case "setTitle":
      let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else { return }
      onSetTitle?(trimmed)
    default:
      break
    }
  }

  private func installUserScripts() {
    let contentController = webView.configuration.userContentController
    contentController.removeAllUserScripts()
    contentController.addUserScript(
      WKUserScript(
        source: bridgeStateScript(),
        injectionTime: .atDocumentStart,
        forMainFrameOnly: false
      )
    )
    if let bridge = Self.bridgeScriptSource {
      contentController.addUserScript(
        WKUserScript(
          source: bridge,
          injectionTime: .atDocumentStart,
          forMainFrameOnly: false
        )
      )
    }
  }

  private func bridgeStateScript() -> String {
    """
    window.__codevisorBridgeState = \(stateJSON());
    (function () {
      function apply() {
        var state = window.__codevisorBridgeState || {};
        var vars = state.themeVariables || {};
        var root = document.documentElement;
        if (!root) { return; }
        for (var key in vars) { root.style.setProperty(key, vars[key]); }
      }
      apply();
      document.addEventListener("DOMContentLoaded", apply);
    })();
    """
  }

  private func themeUpdateScript() -> String {
    """
    (function () {
      var state = (window.__codevisorBridgeState = window.__codevisorBridgeState || {});
      var next = \(stateJSON());
      state.themeVariables = next.themeVariables;
      state.context = state.context || {};
      state.context.themeMode = next.context.themeMode;
      var root = document.documentElement;
      if (root) {
        var vars = state.themeVariables;
        for (var key in vars) { root.style.setProperty(key, vars[key]); }
      }
      window.dispatchEvent(
        new CustomEvent("codevisor:themechange", {
          detail: { themeMode: state.context.themeMode }
        })
      );
    })();
    """
  }

  private func stateJSON() -> String {
    var contextObject: [String: Any] = [
      "paneId": context.paneId,
      "themeMode": context.themeMode,
    ]
    if let workspaceId = context.workspaceId { contextObject["workspaceId"] = workspaceId }
    if let cwd = context.cwd { contextObject["cwd"] = cwd }
    let state: [String: Any] = [
      "context": contextObject,
      "themeVariables": theme.variables,
    ]
    guard
      let data = try? JSONSerialization.data(withJSONObject: state, options: [.sortedKeys]),
      let json = String(data: data, encoding: .utf8)
    else { return "{}" }
    return json
  }

  private static func externalURL(_ url: URL) -> URL? {
    switch url.scheme?.lowercased() {
    case "http", "https", "mailto":
      url
    default:
      nil
    }
  }

  private func openExternally(_ url: URL) {
    #if canImport(AppKit)
      NSWorkspace.shared.open(url)
    #else
      UIApplication.shared.open(url)
    #endif
  }

  private func applyBackground() {
    guard let background = theme.background else { return }
    #if canImport(AppKit)
      webView.setValue(false, forKey: "drawsBackground")
      webView.underPageBackgroundColor = NSColor(
        srgbRed: background.r / 255, green: background.g / 255,
        blue: background.b / 255, alpha: 1
      )
    #else
      webView.underPageBackgroundColor = UIColor(
        red: background.r / 255, green: background.g / 255,
        blue: background.b / 255, alpha: 1
      )
      webView.isOpaque = false
      webView.backgroundColor = webView.underPageBackgroundColor
    #endif
  }

  private static func isNavigationNoise(_ error: any Error) -> Bool {
    let nsError = error as NSError
    return nsError.code == NSURLErrorCancelled
      || (nsError.domain == "WebKitErrorDomain" && nsError.code == 102)
  }

  fileprivate func navigationFailed(_ error: any Error, provisional: Bool = false) {
    guard !Self.isNavigationNoise(error) else { return }
    onNavigationFailed?(error.localizedDescription)
    if WebConnectionRecovery.accepts(error, method: mainFrameMethod, provisional: provisional) {
      onConnectionFailure?(error)
    }
  }
}

extension WebPaneController: WKNavigationDelegate {
  public func webView(
    _ webView: WKWebView,
    decidePolicyFor navigationAction: WKNavigationAction
  ) async -> WKNavigationActionPolicy {
    if navigationAction.targetFrame?.isMainFrame == true {
      mainFrameMethod = navigationAction.request.httpMethod
    }
    guard let url = navigationAction.request.url else { return .cancel }
    if url.scheme?.lowercased() == "about" { return .allow }
    if let allowedOrigin, WebPaneOrigin(url: url) == allowedOrigin { return .allow }
    if navigationAction.targetFrame?.isMainFrame != false,
      let external = Self.externalURL(url)
    {
      openExternally(external)
    }
    return .cancel
  }

  public func webView(
    _ webView: WKWebView,
    didFailProvisionalNavigation navigation: WKNavigation!,
    withError error: any Error
  ) {
    navigationFailed(error, provisional: true)
  }

  public func webView(
    _ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error
  ) {
    navigationFailed(error)
  }

  public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    onNavigationFinished?()
  }
}

extension WebPaneController: WKUIDelegate {
  public func webView(
    _ webView: WKWebView,
    createWebViewWith configuration: WKWebViewConfiguration,
    for navigationAction: WKNavigationAction,
    windowFeatures: WKWindowFeatures
  ) -> WKWebView? {
    if let url = navigationAction.request.url, let external = Self.externalURL(url) {
      openExternally(external)
    }
    return nil
  }
}

#if canImport(AppKit)
  public struct WebPaneView: NSViewRepresentable {
    private let controller: WebPaneController

    public init(controller: WebPaneController) {
      self.controller = controller
    }

    public func makeNSView(context: Context) -> WKWebView {
      controller.webView
    }

    public func updateNSView(_ nsView: WKWebView, context: Context) {}
  }
#else
  public struct WebPaneView: UIViewRepresentable {
    private let controller: WebPaneController

    public init(controller: WebPaneController) {
      self.controller = controller
    }

    public func makeUIView(context: Context) -> WKWebView {
      controller.webView
    }

    public func updateUIView(_ uiView: WKWebView, context: Context) {}
  }
#endif
