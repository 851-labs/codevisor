import AppKit
import CodevisorClient
import CodevisorCore
import CodevisorUI
import CryptoKit
import Observation

@MainActor
@Observable
final class ChromiumBrowserModel {
  let machineName: String
  let paneId: UUID
  let isLocal: Bool
  let suggestions: BrowserSuggestions
  private(set) var webView: CVChromiumView?
  private(set) var url: URL?
  private(set) var title = "Browser"
  private(set) var favicon: NSImage?
  private(set) var isLoading = false
  private(set) var canGoBack = false
  private(set) var canGoForward = false
  private(set) var zoomPercent = 100
  private(set) var canZoomOut = false
  private(set) var canZoomIn = false
  private(set) var canResetZoom = false
  private(set) var zoomPresentationRequest = 0
  private(set) var errorMessage: String?
  var addressFocusRequest = 0
  var viewport: ChromiumViewport?
  @ObservationIgnored private var synchronized = false
  @ObservationIgnored private var readyError: Error?
  @ObservationIgnored private var userNavigation = false
  @ObservationIgnored var automationInitialURL: String?
  @ObservationIgnored private var readyWaiters: [CheckedContinuation<CVChromiumView, Error>] = []
  @ObservationIgnored var onNavigate: ((String, String) -> Void)?
  @ObservationIgnored private let machineId: String
  @ObservationIgnored private let client: any CodevisorServerClienting
  @ObservationIgnored private let resolveBaseURL: @MainActor () async -> URL?
  @ObservationIgnored private var loadTask: Task<Void, Never>?
  @ObservationIgnored private var generation = UUID()
  @ObservationIgnored private var cookieSync: BrowserCookieSync?
  @ObservationIgnored private let paneSync: BrowserPaneSync
  @ObservationIgnored private var activationTask: Task<Void, Never>?
  @ObservationIgnored private var backgroundHost: NSWindow?
  @ObservationIgnored private var needsBackgroundHost = false
  @ObservationIgnored private var isVisible = false
  @ObservationIgnored private var retentionRevision = 0
  @ObservationIgnored var onClose: (() -> Void)?
  @ObservationIgnored var onSelect: (() -> Void)?

  init(
    paneId: UUID, machineId: String, machineName: String, initialURL: String?, isLocal: Bool = false,
    client: any CodevisorServerClienting,
    resolveBaseURL: @escaping @MainActor () async -> URL?
  ) {
    self.paneId = paneId
    self.isLocal = isLocal
    paneSync = BrowserPaneSync(paneId: paneId, client: client)
    self.machineId = machineId
    self.machineName = machineName
    self.client = client
    self.resolveBaseURL = resolveBaseURL
    let provider = BrowserSearchProvider(client: client, resolveBaseURL: resolveBaseURL)
    suggestions = BrowserSuggestions(profile: machineId, fetch: provider.suggestions)
    url = BrowserLocation.navigationURL(initialURL ?? "https://www.google.com/")
  }

  func start() {
    guard webView == nil, loadTask == nil else { return }
    BrowserPageRetention.shared.touch(self)
    isLoading = true
    errorMessage = nil
    let token = UUID()
    generation = token
    loadTask = Task { [weak self] in
      guard let self else { return }
      defer { if generation == token { loadTask = nil } }
      do {
        let info = try await client.info()
        guard info.features?.contains("browser-http-proxy-v1") == true,
          info.features?.contains("browser-state-v1") == true
        else {
          throw BrowserError.serverUpdateRequired
        }
        let credential = try await client.browserProxySession()
        guard let endpoint = await resolveBaseURL(), let host = endpoint.host,
          ["http", "https"].contains(endpoint.scheme)
        else { throw URLError(.notConnectedToInternet) }
        try Task.checkCancellation()
        guard generation == token else { return }
        let profile = SHA256.hash(data: Data(machineId.utf8)).map { String(format: "%02x", $0) }.joined()
        let view = CVChromiumView(
          profile: profile, proxyHost: host, proxyPort: endpoint.port ?? (endpoint.scheme == "https" ? 443 : 80),
          proxyTLS: endpoint.scheme == "https", username: credential.username, password: credential.password,
          address: "about:blank"
        )
        wireView(view, token: token)
        webView = view
        // Admit local panes while they initialize, so automation can report a
        // blocked browser instead of mistaking it for an empty tab list.
        if isLocal { ChromiumAutomationBridge.shared.register(self) }
        if needsBackgroundHost { hostInBackgroundIfNeeded(view) }
      } catch {
        guard !Task.isCancelled, generation == token else { return }
        completeReady(.failure(error))
        errorMessage = error.localizedDescription
        isLoading = false
      }
    }
  }

  @ObservationIgnored var onOpenLink: ((String, BrowserLinkDestination, CVChromiumView?) -> Bool)?
  @ObservationIgnored private(set) var browserWindow: ChromiumBrowserWindow?

  /// CEF owns the pending navigation. Adopt its actual page without loading the
  /// URL again, so form submissions, window.opener and window.close keep working.
  func adoptPopup(_ view: CVChromiumView) {
    BrowserPageRetention.shared.touch(self)
    isLoading = true
    wireView(view, token: generation, adopted: true)
    webView = view
    if isLocal { ChromiumAutomationBridge.shared.register(self) }
    hostInBackgroundIfNeeded(view)
  }

  private func wireView(_ view: CVChromiumView, token: UUID, adopted: Bool = false) {
    view.zoomChanged = { [weak self] percent, canZoomOut, canZoomIn, canReset in
      Task { @MainActor [weak self] in
        guard let self, self.generation == token else { return }
        self.zoomPercent = percent
        self.canZoomOut = canZoomOut
        self.canZoomIn = canZoomIn
        self.canResetZoom = canReset
      }
    }
    view.openLink = { [weak self] address, destination in
      self?.onOpenLink?(address, destination.workspaceDestination, nil) ?? false
    }
    view.adoptPopup = { [weak self] popup, address, destination in
      self?.onOpenLink?(address, destination.workspaceDestination, popup) ?? false
    }
    view.pageClosed = { [weak self] in
      guard let self, self.generation == token else { return }
      self.onClose?()
    }
    view.viewportScaleChanged = { [weak self, weak view] scale in
      Task { @MainActor [weak self, weak view] in
        guard let self, let view, self.generation == token, let viewport = self.viewport else { return }
        var metrics = viewport.parameters
        metrics["scale"] = scale
        metrics["dontSetVisibleSize"] = true
        _ = try? await view.cdp("Emulation.setDeviceMetricsOverride", metrics)
      }
    }
    view.stateChanged = { [weak self] address, title, loading, back, forward in
      // CEF callbacks can arrive while SwiftUI is mounting its native view.
      Task { @MainActor [weak self] in
        guard let self, self.generation == token else { return }
        if let current = URL(string: address), ["http", "https"].contains(current.scheme) { self.url = current }
        self.title = title.isEmpty ? (self.url?.host ?? "Browser") : title
        self.browserWindow?.window?.title = self.title
        self.isLoading = loading
        if loading { self.paneSync.cancelActivation() }
        self.canGoBack = back
        self.canGoForward = forward
        if !loading, let location = BrowserLocation.sharedURL(address) {
          BrowserHistory.shared.record(url: address, title: self.title, profile: self.machineId)
          self.paneSync.publish(url: location.absoluteString, title: self.title, cookies: self.cookieSync) {
            [weak self] in
            self?.onNavigate?(location.absoluteString, self?.title ?? "Browser")
          }
        }
      }
    }
    view.loadFailed = { [weak self] message in
      Task { @MainActor [weak self] in
        guard let self, self.generation == token else { return }
        self.errorMessage = "Couldn’t load this page through \(self.machineName). \(message)"
        self.isLoading = false
        if self.webView?.browserIsReady != true {
          self.completeReady(.failure(ChromiumProtocolError(message)))
        }
      }
    }
    view.faviconChanged = { [weak self] data in
      Task { @MainActor [weak self] in
        guard let self, self.generation == token else { return }
        self.favicon = data.flatMap { NSImage(data: $0) }
      }
    }
    view.browserReady = { [weak self, weak view] in
      Task { @MainActor [weak self, weak view] in
        guard let self, let view, self.generation == token else { return }
        do {
          self.cookieSync = ChromiumProfiles.shared.attach(view, machineId: self.machineId, client: self.client)
          if adopted {
            self.synchronized = true
            self.paneSync.recordLoadedCookies(self.cookieSync)
            self.completeReady(.success(view))
            if self.isLocal { ChromiumAutomationBridge.shared.register(self) }
            return
          }
          try await self.cookieSync?.synchronize()
          let saved = try await self.client.browserNavigation(paneId: self.paneId)
          guard self.generation == token else { return }
          self.synchronized = true
          self.paneSync.recordLoadedCookies(self.cookieSync)
          view.navigate(
            self.automationInitialURL ?? (self.userNavigation ? self.url?.absoluteString : saved?.url) ?? self.url?
              .absoluteString ?? "https://www.google.com/")
          self.automationInitialURL = nil
          self.completeReady(.success(view))
          if self.isLocal { ChromiumAutomationBridge.shared.register(self) }
        } catch {
          self.errorMessage = "Couldn’t synchronize browser state. \(error.localizedDescription)";
          self.completeReady(.failure(error))
        }
      }
    }
  }

  func presentInWindow() {
    guard browserWindow == nil else { browserWindow?.showWindow(nil); return }
    let controller = ChromiumBrowserWindow(model: self)
    browserWindow = controller
    controller.showWindow(nil)
    controller.window?.makeKeyAndOrderFront(nil)
  }

  func returnToWorkspace() {
    let previous = browserWindow
    browserWindow = nil
    previous?.detach()
  }

  func windowClosed() {
    browserWindow = nil
    onClose?()
  }

  func synchronizeCookies() async throws { try await cookieSync?.synchronize() }

  func readyView() async throws -> CVChromiumView {
    needsBackgroundHost = true
    if let readyError { throw readyError }
    if let view = webView { hostInBackgroundIfNeeded(view) }
    if let view = webView, view.browserIsReady, synchronized { return view }
    start()
    return try await withCheckedThrowingContinuation { readyWaiters.append($0) }
  }

  /// CEF needs an NSWindow even before SwiftUI mounts a background tab. This
  /// window is never ordered onscreen; the pane takes the same view when opened.
  private func hostInBackgroundIfNeeded(_ view: CVChromiumView) {
    guard view.window == nil else { return }
    if backgroundHost == nil {
      let window = NSWindow(
        contentRect: view.bounds, styleMask: .borderless, backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      window.isExcludedFromWindowsMenu = true
      backgroundHost = window
    }
    backgroundHost?.contentView?.addSubview(view)
  }
  private func completeReady(_ result: Result<CVChromiumView, Error>) {
    if case .failure(let error) = result { readyError = error }
    let waiters = readyWaiters; readyWaiters = []
    for waiter in waiters { waiter.resume(with: result) }
  }

  func submitAddress(_ address: String) {
    guard let target = BrowserLocation.addressBarURL(address) else {
      errorMessage = "Enter a search term or an HTTP or HTTPS address."
      return
    }
    userNavigation = true
    suggestions.dismiss()
    activationTask?.cancel()
    paneSync.cancelActivation()
    url = target
    errorMessage = nil
    isLoading = true
    if let webView, synchronized { webView.navigate(target.absoluteString) } else { start() }
  }

  func reload(ignoringCache: Bool = false) {
    // A failed navigation still has a live CEF browser. Retain it so a hard
    // refresh retries that navigation with CEF's cache-bypass semantics.
    if ignoringCache, synchronized, let webView, webView.browserIsReady {
      errorMessage = nil
      webView.reloadIgnoringCache()
      return
    }
    if errorMessage != nil { resetBrowser() }
    errorMessage = nil
    if let webView {
      if ignoringCache { webView.reloadIgnoringCache() } else { webView.reload() }
    } else {
      start()
    }
  }
  func stop() { webView?.stop(); isLoading = false }
  func zoom(_ command: BrowserZoomCommand) {
    guard let webView, webView.browserIsReady else { return }
    switch command {
    case .zoomIn: webView.zoomIn()
    case .zoomOut: webView.zoomOut()
    case .reset: webView.resetZoom()
    }
    showZoomControls()
  }
  func showZoomControls() { zoomPresentationRequest += 1 }
  func setVisible(_ visible: Bool) {
    if isVisible != visible { retentionRevision += 1; BrowserPageRetention.shared.touch(self) }
    isVisible = visible
    guard paneSync.setVisible(visible) else { return }
    if webView == nil { start(); return }
    guard synchronized, !isLoading else { return }
    activationTask = Task { [weak self] in
      guard let self else { return }
      await paneSync.activate(cookies: cookieSync, currentURL: url?.absoluteString, fallbackURL: url?.absoluteString) {
        [weak self] address, reload in
        if reload { self?.reload() } else { self?.webView?.navigate(address) }
      }
    }
  }
  func showDevTools() { webView?.showDevTools() }
  func focusAddress() { addressFocusRequest += 1 }
  func teardown() {
    returnToWorkspace()
    isVisible = false
    _ = paneSync.setVisible(false)
    BrowserPageRetention.shared.remove(self)
    suggestions.dismiss()
    resetBrowser()
    onNavigate = nil
  }
  private func resetBrowser() {
    zoomPercent = 100
    canZoomOut = false
    canZoomIn = false
    canResetZoom = false
    synchronized = false
    completeReady(.failure(ChromiumProtocolError("Browser closed")))
    readyError = nil
    ChromiumAutomationBridge.shared.unregister(paneId)
    activationTask?.cancel()
    generation = UUID()
    loadTask?.cancel()
    loadTask = nil
    ChromiumProfiles.shared.detach(webView, machineId: machineId)
    webView?.closeBrowser()
    webView = nil
    backgroundHost?.close()
    backgroundHost = nil
  }
}

extension ChromiumBrowserModel: RetainedBrowserPage {
  var hasLiveBrowserPage: Bool { webView != nil || loadTask != nil }
  var protectsBrowserPage: Bool {
    isVisible || isLoading || webView?.hasOpenDevTools == true
      || ChromiumAutomationBridge.shared.isControlling(self)
  }
  func discardBrowserPage() async -> Bool {
    guard !protectsBrowserPage, let view = webView else { return false }
    let activity = retentionRevision
    let token = generation
    let result = try? await view.cdp(
      "Runtime.evaluate", ["expression": BrowserPageActivity.canDiscardScript, "returnByValue": true])
    guard (result?["result"] as? [String: Any])?["value"] as? Bool == true,
      generation == token, retentionRevision == activity, !protectsBrowserPage
    else { return false }
    resetBrowser()
    userNavigation = false
    return true
  }
}

private enum BrowserError: LocalizedError {
  case serverUpdateRequired
  var errorDescription: String? { "Update the Codevisor server on this machine to use Chromium browser panes." }
}

extension CVBrowserLinkDestination {
  var workspaceDestination: BrowserLinkDestination {
    switch self {
    case .foregroundTab: .foregroundTab
    case .window: .window
    case .splitRight: .split(.trailing)
    case .splitLeft: .split(.leading)
    case .splitAbove: .split(.top)
    case .splitBelow: .split(.bottom)
    default: .backgroundTab
    }
  }
}
