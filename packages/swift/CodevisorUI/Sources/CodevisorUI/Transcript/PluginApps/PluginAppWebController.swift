import Foundation
import WebKit

#if canImport(AppKit)
  import AppKit
#else
  import UIKit
#endif

@MainActor
public final class PluginAppWebController: NSObject {
  public enum LoadFailure: Equatable, Sendable {
    case unauthorized
    case failed(String)
  }

  static let messageName = "codevisorApp"

  private static let dataStore = WKWebsiteDataStore.nonPersistent()

  private static let subframeSchemes: Set<String> = ["about", "data", "blob", "http", "https"]

  public let webView: WKWebView
  var onMessage: ((PluginAppNativeMessage) -> Void)?
  var onLoaded: (() -> Void)?
  var onFailed: ((LoadFailure) -> Void)?
  var onTerminated: (() -> Void)?

  private var allowedOrigin: PluginAppOrigin?

  var contextActions: [PluginAppContextAction] = [] {
    didSet {
      #if os(macOS)
        (webView as? PluginAppNativeWebView)?.contextActions = contextActions
      #endif
    }
  }

  override public init() {
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = Self.dataStore
    configuration.userContentController = WKUserContentController()
    #if os(iOS)
      configuration.allowsInlineMediaPlayback = true
      configuration.dataDetectorTypes = []
    #endif
    #if os(macOS)
      webView = PluginAppNativeWebView(frame: .zero, configuration: configuration)
    #else
      webView = WKWebView(frame: .zero, configuration: configuration)
    #endif
    super.init()
    configuration.userContentController.add(PluginAppMessageProxy(controller: self), name: Self.messageName)
    webView.navigationDelegate = self
    webView.uiDelegate = self
    #if DEBUG
      webView.isInspectable = true
    #endif
    makeTransparent()
  }

  public func load(_ url: URL) {
    allowedOrigin = PluginAppOrigin(url: url)
    #if os(macOS)
      if let menuView = webView as? PluginAppNativeWebView, !menuView.isWindowVisible {
        menuView.whenVisible { [weak self] in self?.webView.load(URLRequest(url: url)) }
        return
      }
    #endif
    webView.load(URLRequest(url: url))
  }

  func setTheme(_ theme: String) async -> Bool {
    await callHost("window.codevisorHost.setTheme(theme)", arguments: ["theme": theme])
  }

  func notifyDisplayMode(_ mode: PluginAppDisplayMode, requestId: String?) async {
    let arguments: [String: Any] = ["mode": mode.rawValue, "requestId": requestId ?? NSNull()]
    _ = await callHost("window.codevisorHost.displayModeChanged(mode, requestId)", arguments: arguments)
  }

  private func callHost(_ body: String, arguments: [String: Any]) async -> Bool {
    do {
      _ = try await webView.callAsyncJavaScript(body, arguments: arguments, contentWorld: .page)
      return true
    } catch {
      return false
    }
  }

  func receive(_ body: Any) {
    guard let message = PluginAppNativeMessage(body: body) else { return }
    onMessage?(message)
  }

  static func openExternally(_ url: URL) {
    #if canImport(AppKit)
      NSWorkspace.shared.open(url)
    #else
      UIApplication.shared.open(url)
    #endif
  }

  private func makeTransparent() {
    #if canImport(AppKit)
      webView.setValue(false, forKey: "drawsBackground")
      webView.underPageBackgroundColor = .clear
    #else
      webView.isOpaque = false
      webView.backgroundColor = .clear
      webView.scrollView.backgroundColor = .clear
      webView.scrollView.isScrollEnabled = false
      webView.scrollView.bounces = false
      webView.scrollView.contentInsetAdjustmentBehavior = .never
    #endif
  }

  private func policy(for action: WKNavigationAction) -> WKNavigationActionPolicy {
    guard let url = action.request.url else { return .cancel }
    guard action.targetFrame?.isMainFrame != false else { return subframePolicy(for: url) }
    if let allowedOrigin, PluginAppOrigin(url: url) == allowedOrigin { return .allow }

    if let external = PluginAppNativeMessage.externalURL(url) { Self.openExternally(external) }
    return .cancel
  }

  private func subframePolicy(for url: URL) -> WKNavigationActionPolicy {
    guard let scheme = url.scheme?.lowercased(), Self.subframeSchemes.contains(scheme) else { return .cancel }
    return .allow
  }

  private func policy(for response: WKNavigationResponse) -> WKNavigationResponsePolicy {
    guard response.isForMainFrame, let status = (response.response as? HTTPURLResponse)?.statusCode,
      status >= 400
    else { return .allow }

    onFailed?(Self.failure(status: status))
    return .cancel
  }

  private static func failure(status: Int) -> LoadFailure {
    if status == 401 { return .unauthorized }
    return .failed("The app couldn’t load (HTTP \(status)).")
  }

  private func navigationFailed(_ error: any Error) {
    let nsError = error as NSError
    guard nsError.code != NSURLErrorCancelled, !Self.isPolicyInterruption(nsError) else { return }
    onFailed?(.failed(nsError.localizedDescription))
  }

  private static func isPolicyInterruption(_ error: NSError) -> Bool {
    error.domain == "WebKitErrorDomain" && error.code == 102
  }
}

extension PluginAppWebController: WKNavigationDelegate {
  public func webView(
    _ webView: WKWebView,
    decidePolicyFor navigationAction: WKNavigationAction
  ) async -> WKNavigationActionPolicy {
    policy(for: navigationAction)
  }

  public func webView(
    _ webView: WKWebView,
    decidePolicyFor navigationResponse: WKNavigationResponse
  ) async -> WKNavigationResponsePolicy {
    policy(for: navigationResponse)
  }

  public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    onLoaded?()
  }

  public func webView(
    _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error
  ) {
    navigationFailed(error)
  }

  public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
    navigationFailed(error)
  }

  public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
    onTerminated?()
  }
}

extension PluginAppWebController: WKUIDelegate {
  public func webView(
    _ webView: WKWebView,
    createWebViewWith configuration: WKWebViewConfiguration,
    for navigationAction: WKNavigationAction,
    windowFeatures: WKWindowFeatures
  ) -> WKWebView? {
    if let url = navigationAction.request.url, let external = PluginAppNativeMessage.externalURL(url) {
      Self.openExternally(external)
    }
    return nil
  }

  public func webView(
    _ webView: WKWebView,
    decideMediaCapturePermissionsFor origin: WKSecurityOrigin,
    initiatedBy frame: WKFrameInfo,
    type: WKMediaCaptureType
  ) async -> WKPermissionDecision {
    .deny
  }

  #if os(iOS)
    public func webView(
      _ webView: WKWebView,
      requestDeviceOrientationAndMotionPermissionFor origin: WKSecurityOrigin,
      initiatedByFrame frame: WKFrameInfo,
      decisionHandler: @escaping @MainActor (WKPermissionDecision) -> Void
    ) {
      decisionHandler(.deny)
    }
  #endif
}
