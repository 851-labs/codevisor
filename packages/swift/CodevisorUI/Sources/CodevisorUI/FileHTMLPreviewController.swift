import Foundation
import WebKit

@MainActor
final class FileHTMLPreviewController: NSObject {
  private static let resourceCheckInterval = Duration.seconds(3)

  let webView: WKWebView
  var openFile: (String) -> Bool = { _ in false }
  var openWebLink: (URL) -> Void = { _ in }
  var openExternally: (URL) -> Void = { _ in }
  var watchesResources = true
  private let address: FileHTMLPreviewAddress
  private let resources: FileHTMLSchemeHandler
  private var shownText: String
  private var pendingScroll: [Double]?
  private var resourceWatch: Task<Void, Never>?

  init(address: FileHTMLPreviewAddress, text: String, resources: FileHTMLSchemeHandler) {
    self.address = address
    self.resources = resources
    shownText = text
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    configuration.setURLSchemeHandler(resources, forURLScheme: FileHTMLPreviewAddress.scheme)
    webView = WKWebView(frame: .zero, configuration: configuration)
    super.init()
    webView.navigationDelegate = self
    webView.uiDelegate = self
    #if DEBUG
      webView.isInspectable = true
    #endif
    webView.load(URLRequest(url: address.pageURL))
    watchResources()
  }

  func show(_ text: String) {
    guard text != shownText else { return }

    shownText = text
    reloadKeepingScroll()
  }

  func stopWatching() {
    resourceWatch?.cancel()
  }

  private func watchResources() {
    resourceWatch = Task { [weak self] in
      while !Task.isCancelled {
        do { try await Task.sleep(for: Self.resourceCheckInterval) } catch { return }
        guard let self else { return }
        await reloadIfResourcesChanged()
      }
    }
  }

  private func reloadIfResourcesChanged() async {
    guard watchesResources, await resources.resourcesChanged() else { return }

    reloadKeepingScroll()
  }

  private func reloadKeepingScroll() {
    webView.evaluateJavaScript("[window.scrollX, window.scrollY]") { [weak self] offset, _ in
      self?.pendingScroll = offset as? [Double]
      self?.webView.reload()
    }
  }

  private func restoreScroll() {
    guard let offset = pendingScroll, offset.count == 2 else { return }

    pendingScroll = nil
    webView.evaluateJavaScript("window.scrollTo(\(offset[0]), \(offset[1]))")
  }

  private func perform(_ navigation: FileHTMLPreviewNavigation) -> WKNavigationActionPolicy {
    switch navigation {
    case .allow: return .allow
    case .cancel: break
    case let .openFile(target): _ = openFile(target)
    case let .openWebLink(url): openWebLink(url)
    case let .openExternally(url): openExternally(url)
    }
    return .cancel
  }
}

extension FileHTMLPreviewController: WKNavigationDelegate {
  func webView(
    _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction
  ) async -> WKNavigationActionPolicy {
    perform(
      FileHTMLPreviewNavigation.decide(
        url: navigationAction.request.url, isMainFrame: navigationAction.targetFrame?.isMainFrame ?? true,
        isLinkActivated: navigationAction.navigationType == .linkActivated, address: address))
  }

  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    restoreScroll()
  }
}

extension FileHTMLPreviewController: WKUIDelegate {
  func webView(
    _ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
    for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures
  ) -> WKWebView? {
    guard navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url else { return nil }

    _ = perform(FileHTMLPreviewNavigation.link(url))
    return nil
  }
}
