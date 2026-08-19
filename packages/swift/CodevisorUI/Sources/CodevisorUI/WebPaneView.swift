//  The one WebKit surface in the codebase: plugin panes are a deliberate,
//  contained exception to the "no webviews" rule, and every WebKit detail
//  stays inside this file (plus the plugin-bridge.js resource it injects).
//
//  A WebPaneController owns a WKWebView configured with bridge v1 (frozen):
//  `window.codevisor.getContext()/openUrl()/setTitle()`, `--codevisor-*`
//  CSS custom properties on `:root`, and the `codevisor:themechange` window
//  event. Navigation is scoped to the pane's proxy origin — anything else is
//  cancelled and routed to the system browser. WebPaneView is the SwiftUI
//  host; panes cache their controller so tab switches never reload.

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

/// The values `window.codevisor.getContext()` returns, templated into the
/// bridge's document-start user script.
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

/// The bridge's theme surface: "light"/"dark" plus the `--codevisor-*` CSS
/// custom properties, derived from the active `DerivedPalette` (or the stock
/// system look when no palette is active).
public struct WebPaneThemeTokens: Equatable, Sendable {
    public var mode: String
    /// CSS custom property name -> CSS value, applied to `:root`.
    public var variables: [String: String]
    /// The pane surface color, painted behind the document so loads never
    /// flash a white webview.
    public var background: RGBA?

    public init(mode: String, variables: [String: String], background: RGBA? = nil) {
        self.mode = mode
        self.variables = variables
        self.background = background
    }

    public init(palette: DerivedPalette?, isDark: Bool) {
        let mode = (palette?.isDark ?? isDark) ? "dark" : "light"
        guard let palette else {
            self.init(
                mode: mode,
                variables: Self.systemVariables(isDark: isDark),
                background: isDark ? RGBA(r: 30, g: 30, b: 30) : RGBA(r: 255, g: 255, b: 255)
            )
            return
        }
        var variables = Self.fontVariables
        variables["--codevisor-bg"] = Self.css(palette.windowBackground)
        variables["--codevisor-bg-elevated"] = Self.css(palette.cardBackground)
        variables["--codevisor-fg"] = Self.css(palette.textPrimary)
        variables["--codevisor-fg-secondary"] = Self.css(palette.textSecondary)
        variables["--codevisor-fg-tertiary"] = Self.css(palette.textTertiary)
        variables["--codevisor-border"] = Self.css(palette.border)
        variables["--codevisor-separator"] = Self.css(palette.separator)
        variables["--codevisor-accent"] = Self.css(palette.accent)
        variables["--codevisor-status-ok"] = Self.css(palette.statusOK)
        variables["--codevisor-status-warn"] = Self.css(palette.statusWarn)
        variables["--codevisor-status-error"] = Self.css(palette.statusError)
        variables["--codevisor-diff-added"] = Self.css(palette.diffAddedFg)
        variables["--codevisor-diff-removed"] = Self.css(palette.diffRemovedFg)
        variables["--codevisor-diff-added-bg"] = Self.css(palette.diffAddedBg)
        variables["--codevisor-diff-removed-bg"] = Self.css(palette.diffRemovedBg)
        self.init(mode: mode, variables: variables, background: palette.windowBackground)
    }

    private static let fontVariables: [String: String] = [
        "--codevisor-font-family": "-apple-system, BlinkMacSystemFont, 'Helvetica Neue', sans-serif",
        "--codevisor-font-family-mono": "ui-monospace, 'SF Mono', Menlo, monospace",
    ]

    /// Stock-look values matching the system light/dark themes closely
    /// enough for plugin chrome (the same constants PaletteDeriver falls
    /// back to for status/diff colors).
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

    private static func css(_ color: RGBA) -> String {
        let r = Int(color.r.rounded())
        let g = Int(color.g.rounded())
        let b = Int(color.b.rounded())
        if color.a >= 1 {
            return "rgb(\(r), \(g), \(b))"
        }
        // %g trims trailing zeros ("0.2", not "0.200").
        return "rgba(\(r), \(g), \(b), \(String(format: "%g", color.a)))"
    }
}

/// scheme+host+port identity used by the navigation policy.
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

/// Breaks the retain cycle WKUserContentController.add would otherwise
/// create (the controller owns the webView which retains its handlers).
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

/// Owns one plugin pane's WKWebView plus its bridge/theme injection and
/// navigation policy. Long-lived: the owning pane caches it so tab switches
/// re-host the same webView without reloading.
@MainActor
public final class WebPaneController: NSObject {
    private static let bridgeMessageName = "codevisorBridge"

    private static let bridgeScriptSource: String? = {
        guard let url = Bundle.module.url(forResource: "plugin-bridge", withExtension: "js")
        else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }()

    public let webView: WKWebView
    /// The plugin called `codevisor.setTitle` — rename the pane's tab.
    public var onSetTitle: ((String) -> Void)?
    /// Off-origin/external navigation. Nil falls back to the system browser.
    public var onOpenExternalURL: ((URL) -> Void)?
    /// A main-frame load failed; the message is user-presentable. The owner
    /// must render a native error state — never a blank webview.
    public var onNavigationFailed: ((String) -> Void)?
    public var onNavigationFinished: (() -> Void)?

    private var context: WebPaneBridgeContext
    private var theme: WebPaneThemeTokens
    private var allowedOrigin: WebPaneOrigin?

    /// A stable per-plugin identity for WKWebsiteDataStore: the same plugin
    /// always maps to the same store (durable HTTP cache + localStorage
    /// across app restarts), and different plugins can never read each
    /// other's storage. Derived from the plugin id so no mapping file is
    /// needed.
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
        // No explicit WKProcessPool: since macOS 12/iOS 15 every WKWebView
        // shares the one web-content process pool automatically.
        let configuration = WKWebViewConfiguration()
        if let dataStoreIdentifier {
            // Identifier-based stores persist to disk under the app's
            // container, so plugin assets served with Cache-Control survive
            // pane teardown and app relaunch.
            configuration.websiteDataStore = WKWebsiteDataStore(forIdentifier: dataStoreIdentifier)
        }
        self.webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        #if DEBUG
            webView.isInspectable = true
        #endif
        configuration.userContentController.add(
            WebPaneMessageProxy(controller: self),
            name: Self.bridgeMessageName
        )
        applyBackground()
        installUserScripts()
    }

    /// Starts (or restarts) the pane load. The URL's origin becomes the only
    /// origin in-webview navigation may stay on.
    public func load(_ url: URL) {
        allowedOrigin = WebPaneOrigin(url: url)
        webView.load(URLRequest(url: url))
    }

    /// Stops any in-flight load — owner teardown, kept here so owners don't
    /// need WebKit member visibility for it.
    public func stopLoading() {
        webView.stopLoading()
    }

    /// Re-injects the theme for future document loads and pushes it into the
    /// live document: CSS vars update in place and the page receives the
    /// bridge's `codevisor:themechange` event.
    public func applyTheme(_ tokens: WebPaneThemeTokens) {
        guard tokens != theme else { return }
        theme = tokens
        context.themeMode = tokens.mode
        applyBackground()
        installUserScripts()
        webView.evaluateJavaScript(themeUpdateScript()) { _, _ in }
    }

    // MARK: - Bridge

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

    /// Seeds `window.__codevisorBridgeState` (what plugin-bridge.js reads)
    /// and applies the `--codevisor-*` variables to `:root`.
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

    /// The bridge state as a JSON literal. JSONSerialization escapes every
    /// templated value, so context strings can never break out of the script.
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

    // MARK: - External navigation

    /// Schemes that may leave the app for the system browser/handlers.
    private static func externalURL(_ url: URL) -> URL? {
        switch url.scheme?.lowercased() {
        case "http", "https", "mailto":
            url
        default:
            nil
        }
    }

    private func openExternally(_ url: URL) {
        if let onOpenExternalURL {
            onOpenExternalURL(url)
            return
        }
        #if canImport(AppKit)
            NSWorkspace.shared.open(url)
        #else
            UIApplication.shared.open(url)
        #endif
    }

    private func applyBackground() {
        guard let background = theme.background else { return }
        #if canImport(AppKit)
            // WKWebView on macOS paints an opaque white page before the first
            // content render, which flashes against dark pane chrome. There is
            // no public opacity API on macOS; this KVC key has been stable
            // since 10.12 and makes the view transparent so the themed pane
            // background underneath shows until the plugin's document paints.
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
        // -999: a new load superseded this one. 102 (WebKitErrorDomain):
        // our own policy cancelled the navigation (external-link routing).
        return nsError.code == NSURLErrorCancelled
            || (nsError.domain == "WebKitErrorDomain" && nsError.code == 102)
    }

    fileprivate func navigationFailed(_ error: any Error) {
        guard !Self.isNavigationNoise(error) else { return }
        onNavigationFailed?(error.localizedDescription)
    }
}

extension WebPaneController: WKNavigationDelegate {
    public func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction
    ) async -> WKNavigationActionPolicy {
        guard let url = navigationAction.request.url else { return .cancel }
        if url.scheme?.lowercased() == "about" { return .allow }
        if let allowedOrigin, WebPaneOrigin(url: url) == allowedOrigin { return .allow }
        // Off-origin: main-frame link-outs go to the system browser
        // (codevisor.openUrl semantics); embedded off-origin content is
        // simply blocked.
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
        navigationFailed(error)
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
    /// target=_blank and window.open land here; both route externally.
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

/// SwiftUI host for a WebPaneController's webView. The controller (and the
/// webView it owns) outlives this view — remounting re-attaches, never
/// reloads.
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
