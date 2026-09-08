import CodevisorClient
import Foundation
import Observation
import WebKit

@MainActor
@Observable
public final class BrowserPaneModel: NSObject {
  public let machineName: String
  public let paneId: UUID
  public private(set) var webView: WKWebView?
  public private(set) var url: URL?
  public private(set) var title = "Browser"
  public var favicon: CGImage? { faviconLoader.image }
  public private(set) var isLoading = false
  public private(set) var progress = 0.0
  public private(set) var canGoBack = false
  public private(set) var canGoForward = false
  public private(set) var errorMessage: String?
  private(set) var pageAppearance = BrowserPageAppearance()
  @ObservationIgnored public var onNavigate: ((String, String) -> Void)?
  @ObservationIgnored public var onFaviconChange: ((CGImage?) -> Void)?
  private let faviconLoader = BrowserFaviconLoader()
  @ObservationIgnored private let machineId: String
  @ObservationIgnored private let client: any CodevisorServerClienting
  @ObservationIgnored private let resolveBaseURL: @MainActor () async -> URL?
  @ObservationIgnored private var observations: [NSKeyValueObservation] = []
  @ObservationIgnored private var loadTask: Task<Void, Never>?
  @ObservationIgnored private var loadGeneration = UUID()
  @ObservationIgnored private var requestedURL: URL?
  @ObservationIgnored private let paneSync: BrowserPaneSync
  @ObservationIgnored private var activationTask: Task<Void, Never>?
  @ObservationIgnored private var navigationMessages: BrowserNavigationMessages?

  public init(
    paneId: UUID, machineId: String, machineName: String, initialURL: String?,
    client: any CodevisorServerClienting,
    resolveBaseURL: @escaping @MainActor () async -> URL?
  ) {
    self.paneSync = BrowserPaneSync(paneId: paneId, client: client)
    self.paneId = paneId
    self.machineId = machineId
    self.machineName = machineName
    self.client = client
    self.resolveBaseURL = resolveBaseURL
    self.requestedURL = initialURL.flatMap(Self.navigationURL)
    self.url = requestedURL
    super.init()
    faviconLoader.onChange = { [weak self] image in self?.onFaviconChange?(image) }
  }

  public static func navigationURL(_ input: String) -> URL? {
    BrowserLocation.navigationURL(input).flatMap(BrowserAddress.proxied)
  }

  static func addressBarURL(_ input: String) -> URL? {
    BrowserLocation.addressBarURL(input).flatMap(BrowserAddress.proxied)
  }

  public func submitAddress(_ input: String) {
    guard let target = Self.addressBarURL(input) else {
      errorMessage = "Enter a search term or an HTTP or HTTPS address."
      return
    }
    navigate(to: target.absoluteString)
  }

  public func start() {
    if webView != nil { return }
    guard loadTask == nil, let requestedURL else { return }
    load(address: requestedURL.absoluteString, adoptShared: true)
  }

  public func setVisible(_ visible: Bool) {
    guard paneSync.setVisible(visible) else { return }
    if webView == nil { start(); return }
    activationTask = Task { [weak self] in
      guard let self else { return }
      await paneSync.activate(
        cookies: BrowserWebsiteProfile.sync(machineId: machineId),
        currentURL: webView?.url.flatMap(BrowserLocation.canonicalURL)?.absoluteString,
        fallbackURL: requestedURL.flatMap(BrowserLocation.canonicalURL)?.absoluteString
      ) { [weak self] address, reload in
        if reload { self?.reload() } else { self?.navigate(to: address) }
      }
    }
  }

  public func navigate(to address: String) {
    load(address: address)
  }

  private func load(address: String, adoptShared: Bool = false) {
    guard let target = Self.navigationURL(address) else {
      errorMessage = "Enter an HTTP or HTTPS address."
      return
    }
    requestedURL = target
    errorMessage = nil
    isLoading = true
    loadTask?.cancel()
    let generation = UUID()
    loadGeneration = generation
    loadTask = Task { [weak self] in
      guard let self else { return }
      defer { if self.loadGeneration == generation { self.loadTask = nil } }
      do {
        let credential = try await self.client.browserProxySession()
        guard let endpoint = await self.resolveBaseURL() else { throw URLError(.notConnectedToInternet) }
        try Task.checkCancellation()
        let store = try BrowserWebsiteProfile.configuredStore(
          machineId: self.machineId, endpoint: endpoint, credential: credential, client: self.client
        )
        var loadTarget = target
        if self.webView == nil {
          try await BrowserWebsiteProfile.sync(machineId: self.machineId)?.synchronize()
          if adoptShared, let saved = try await client.browserNavigation(paneId: paneId),
            let latest = Self.navigationURL(saved.url)
          {
            loadTarget = latest
          }
          let view = try await BrowserNetworkRules.makeWebView(store: store)
          try Task.checkCancellation()
          self.configureWebView(view)
          BrowserWebsiteProfile.retain(machineId: machineId, paneId: paneId)
        }
        self.webView?.load(URLRequest(url: loadTarget))
      } catch {
        guard !Task.isCancelled else { return }
        self.errorMessage = "Couldn’t connect through \(self.machineName). \(error.localizedDescription)"
        self.isLoading = false
      }
    }
  }

  public func reload() {
    if errorMessage == nil, let webView, webView.url != nil {
      isLoading = webView.reload() != nil
      return
    }
    if let target = webView?.url ?? requestedURL { load(address: target.absoluteString) }
  }

  public func stop() {
    loadGeneration = UUID()
    loadTask?.cancel()
    loadTask = nil
    webView?.stopLoading()
    isLoading = false
  }

  public func teardown() {
    BrowserWebsiteProfile.release(machineId: machineId, paneId: paneId)
    stop()
    activationTask?.cancel()
    _ = paneSync.setVisible(false)
    onNavigate = nil
    onFaviconChange = nil
    faviconLoader.stop()
    webView?.configuration.userContentController.removeScriptMessageHandler(forName: "codevisorBrowserNavigation")
    navigationMessages = nil
    observations.removeAll()
    webView?.navigationDelegate = nil
    webView?.uiDelegate = nil
    webView = nil
  }

  private func configureWebView(_ view: WKWebView) {
    view.navigationDelegate = self
    view.uiDelegate = self
    view.allowsBackForwardNavigationGestures = true
    let messages = BrowserNavigationMessages(model: self)
    navigationMessages = messages
    view.configuration.userContentController.add(messages, name: "codevisorBrowserNavigation")
    if let path = Bundle.module.url(forResource: "browser-navigation", withExtension: "js"),
      let script = try? String(contentsOf: path, encoding: .utf8)
    {
      view.configuration.userContentController.addUserScript(
        WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page))
    }
    #if DEBUG
      view.isInspectable = true
    #endif
    webView = view
    observations = [
      view.observe(\.isLoading, options: [.new]) { [weak self] _, _ in
        Task { @MainActor in self?.updateState() }
      },
      view.observe(\.estimatedProgress, options: [.new]) { [weak self] _, _ in
        Task { @MainActor in self?.updateState() }
      },
      view.observe(\.title, options: [.new]) { [weak self] _, _ in
        Task { @MainActor in self?.updateState(publish: true) }
      },
      view.observe(\.url, options: [.new]) { [weak self] _, _ in
        Task { @MainActor in self?.updateState(publish: true) }
      },
      view.observe(\.underPageBackgroundColor, options: [.initial, .new]) { [weak self] _, _ in
        Task { @MainActor in self?.updateAppearance() }
      },
      view.observe(\.themeColor, options: [.new]) { [weak self] _, _ in
        Task { @MainActor in self?.updateAppearance() }
      },
    ]
  }

  private func updateAppearance() {
    guard let webView else { return }
    pageAppearance = BrowserPageAppearance(background: webView.underPageBackgroundColor, theme: webView.themeColor)
    #if os(iOS)
      // Do not assign underPageBackgroundColor: that would override WebKit's
      // automatic updates when the page's CSS or color scheme changes.
      webView.scrollView.backgroundColor = webView.underPageBackgroundColor
    #endif
  }

  private func updateState(publish: Bool = false) {
    guard let webView else { return }
    progress = webView.estimatedProgress
    isLoading = webView.isLoading
    canGoBack = webView.canGoBack
    canGoForward = webView.canGoForward
    if let current = webView.url, ["http", "https"].contains(current.scheme) {
      url = current
      requestedURL = current
      title = webView.title.flatMap { $0.isEmpty ? nil : $0 } ?? current.host ?? "Browser"
      if publish && !webView.isLoading { publishNavigation(current.absoluteString) }
    }
  }

  fileprivate func pageMessage(kind: String, address: String) {
    guard let webView, !webView.isLoading, kind == "location",
      let target = Self.navigationURL(address)
    else { return }
    url = target
    requestedURL = target
    faviconLoader.refresh(from: webView)
    publishNavigation(target.absoluteString)
  }

  private func publishNavigation(_ address: String) {
    guard let location = BrowserLocation.sharedURL(address) else { return }
    paneSync.publish(
      url: location.absoluteString, title: title, cookies: BrowserWebsiteProfile.sync(machineId: machineId)
    ) { [weak self] in
      self?.onNavigate?(location.absoluteString, self?.title ?? "Browser")
    }
  }

  private func failed(_ error: any Error) {
    guard (error as NSError).code != NSURLErrorCancelled else { return }
    updateState()
    isLoading = false
    errorMessage = "Couldn’t load this page through \(machineName). \(error.localizedDescription)"
  }
}

extension BrowserPaneModel: WKNavigationDelegate {
  public func webView(
    _ webView: WKWebView, decidePolicyFor action: WKNavigationAction
  ) async -> WKNavigationActionPolicy {
    guard let target = action.request.url, let scheme = target.scheme?.lowercased() else { return .cancel }
    if action.targetFrame?.isMainFrame == true,
      let request = BrowserNetworkRules.redirectedNavigation(action.request)
    {
      webView.load(request)
      return .cancel
    }
    // Native rules cover subresources; top-level loads use the navigation delegate.
    // Custom schemes never escape to another app and bypass the machine route.
    return ["http", "https", "about", "blob", "data"].contains(scheme) ? .allow : .cancel
  }

  public func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
    errorMessage = nil
    isLoading = true
  }

  public func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) { faviconLoader.reset() }
  public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    updateState(publish: true)
    faviconLoader.refresh(from: webView)
  }
  public func webView(
    _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error
  ) { failed(error) }
  public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
    failed(error)
  }
  public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
    errorMessage = "This page was closed to free memory. Reload to continue."
    isLoading = false
  }
}

extension BrowserPaneModel: WKUIDelegate {
  public func webView(
    _ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
    for action: WKNavigationAction, windowFeatures: WKWindowFeatures
  ) -> WKWebView? {
    if let target = action.request.url, Self.navigationURL(target.absoluteString) != nil {
      webView.load(BrowserNetworkRules.redirectedNavigation(action.request) ?? action.request)
    }
    return nil
  }
}

@MainActor
private final class BrowserNavigationMessages: NSObject, WKScriptMessageHandler {
  weak var model: BrowserPaneModel?
  init(model: BrowserPaneModel) { self.model = model }
  func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
    guard message.frameInfo.isMainFrame, let body = message.body as? [String: String],
      let kind = body["kind"], let address = body["url"]
    else { return }
    model?.pageMessage(kind: kind, address: address)
  }
}
