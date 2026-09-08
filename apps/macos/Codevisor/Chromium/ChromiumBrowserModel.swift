import AppKit
import CodevisorClient
import CodevisorUI
import CryptoKit
import Observation

@MainActor
@Observable
final class ChromiumBrowserModel {
  let machineName: String
  let paneId: UUID
  let isLocal: Bool
  private(set) var webView: CVChromiumView?
  private(set) var url: URL?
  private(set) var title = "Browser"
  private(set) var favicon: NSImage?
  private(set) var isLoading = false
  private(set) var canGoBack = false
  private(set) var canGoForward = false
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
    url = BrowserLocation.navigationURL(initialURL ?? "https://www.google.com/")
  }

  func start() {
    guard webView == nil, loadTask == nil else { return }
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
            self.isLoading = loading
            self.canGoBack = back
            self.canGoForward = forward
            if !loading, let location = BrowserLocation.sharedURL(address) {
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
              try await self.cookieSync?.synchronize()
              let saved = try await self.client.browserNavigation(paneId: self.paneId)
              guard self.generation == token else { return }
              self.synchronized = true
              self.paneSync.recordLoadedCookies(self.cookieSync)
              view.navigate(
                self.automationInitialURL ?? (self.userNavigation ? self.url?.absoluteString : saved?.url) ?? self.url?
                  .absoluteString ?? "https://www.google.com/")
              self.completeReady(.success(view))
              if self.isLocal { ChromiumAutomationBridge.shared.register(self) }
            } catch {
              self.errorMessage = "Couldn’t synchronize browser state. \(error.localizedDescription)";
              self.completeReady(.failure(error))
            }
          }
        }
        webView = view
        if needsBackgroundHost { hostInBackgroundIfNeeded(view) }
      } catch {
        guard !Task.isCancelled, generation == token else { return }
        completeReady(.failure(error))
        errorMessage = error.localizedDescription
        isLoading = false
      }
    }
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
    url = target
    errorMessage = nil
    isLoading = true
    if let webView, synchronized { webView.navigate(target.absoluteString) } else { start() }
  }

  func reload() {
    if errorMessage != nil { resetBrowser() }
    errorMessage = nil
    if let webView { webView.reload() } else { start() }
  }
  func stop() { webView?.stop(); isLoading = false }
  func setVisible(_ visible: Bool) {
    guard paneSync.setVisible(visible) else { return }
    if webView == nil { start(); return }
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
  func teardown() { resetBrowser(); onNavigate = nil }
  private func resetBrowser() {
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

private enum BrowserError: LocalizedError {
  case serverUpdateRequired
  var errorDescription: String? { "Update the Codevisor server on this machine to use Chromium browser panes." }
}
