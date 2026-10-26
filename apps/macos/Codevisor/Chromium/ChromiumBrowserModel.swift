import AppKit
import CodevisorClient
import CodevisorCore
import CodevisorUI
import Observation

@MainActor
@Observable
final class ChromiumBrowserModel {
  let machineName: String
  let paneId: UUID
  nonisolated let machineId: String
  let suggestions: BrowserSuggestions
  private(set) var webView: CVChromiumView?
  private(set) var url: URL?
  private(set) var hasLoadedPage = false
  private(set) var title = "Browser"
  private(set) var favicon: NSImage?
  private(set) var isLoading = false
  private(set) var canGoBack = false
  private(set) var canGoForward = false
  let pageZoom = ChromiumPageZoom()
  private(set) var pageError: BrowserPageError?
  @ObservationIgnored let finder = ChromiumPageFinder()
  var find: TranscriptFindModel { finder.model }
  @ObservationIgnored let downloads = ChromiumDownloads.shared
  private(set) var snapshot: Data?
  let address = ChromiumAddressFocus()
  var viewport: ChromiumViewport?
  @ObservationIgnored private var synchronized = false
  @ObservationIgnored private let readiness = ChromiumPageReadiness()
  @ObservationIgnored private let firstPage = ChromiumFirstPage()
  @ObservationIgnored var onNavigate: ((String, String) -> Void)?
  @ObservationIgnored let favicons: BrowserFaviconSharing
  @ObservationIgnored private let client: any CodevisorServerClienting
  @ObservationIgnored private let resolveBaseURL: @MainActor () async -> URL?
  @ObservationIgnored private var loadTask: Task<Void, Never>?
  @ObservationIgnored private var generation = UUID()
  @ObservationIgnored private var cookieSync: BrowserCookieSync?
  @ObservationIgnored private let paneSync: BrowserPaneSync
  @ObservationIgnored private var activationTask: Task<Void, Never>?
  @ObservationIgnored private let backgroundHost = ChromiumBackgroundHost()
  @ObservationIgnored private var needsBackgroundHost = false
  @ObservationIgnored private var isVisible = false
  @ObservationIgnored private var retentionRevision = 0
  @ObservationIgnored private let freezer = ChromiumPageFreezer()
  @ObservationIgnored var onClose: (() -> Void)?
  @ObservationIgnored var onSelect: (() -> Void)?

  init(
    paneId: UUID, machineId: String, machineName: String, initialURL: String?,
    client: any CodevisorServerClienting,
    resolveBaseURL: @escaping @MainActor () async -> URL?
  ) {
    self.paneId = paneId
    paneSync = BrowserPaneSync(paneId: paneId, client: client)
    self.machineId = machineId
    self.machineName = machineName
    self.client = client
    favicons = BrowserFaviconSharing(client: client)
    self.resolveBaseURL = resolveBaseURL
    let provider = BrowserSearchProvider(client: client, resolveBaseURL: resolveBaseURL)
    suggestions = BrowserSuggestions(profile: machineId, fetch: provider.suggestions)
    url = BrowserLocation.navigationURL(initialURL ?? "https://www.google.com/")
    finder.page = { [weak self] in self?.webView }
  }

  func start() {
    guard webView == nil, loadTask == nil else { return }
    BrowserPageRetention.shared.touch(self)
    isLoading = true
    pageError = nil
    let token = UUID()
    generation = token
    firstPage.begin(paneId: paneId, client: client)
    if firstPage.knowsAddress, let spare = ChromiumSpareBrowsers.shared.take(machineId: machineId) {
      openInSpare(spare.view, connection: spare.connection, token: token)
    } else {
      loadTask = Task { [weak self] in await self?.launch(token: token) }
    }
  }

  @ObservationIgnored var hasShownPage = false
  @ObservationIgnored private var restartsOnRetry = false

  private var opensBeforeCookieSync: Bool {
    firstPage.knowsAddress && ChromiumProfiles.shared.cookieSync(machineId: machineId)?.isCurrent == true
  }

  private func openInSpare(_ view: CVChromiumView, connection: ChromiumBrowserConnection, token: UUID) {
    install(view, token: token)
    cookieSync = ChromiumProfiles.shared.cookieSync(machineId: machineId)
    view.navigate(firstPage.immediateAddress(current: url))
    pageOpened(view, token: token)
    loadTask = Task { [weak self] in await self?.confirmSpare(connection, token: token) }
  }

  private func confirmSpare(_ connection: ChromiumBrowserConnection, token: UUID) async {
    defer { if generation == token { loadTask = nil } }
    let stale = await ChromiumSpareBrowsers.shared.isStale(
      connection, machineId: machineId, client: client, resolveBaseURL: resolveBaseURL)
    guard stale, generation == token else { return }

    resetBrowser()
    start()
  }

  private func launch(token: UUID) async {
    defer { if generation == token { loadTask = nil } }
    do {
      let connection = try await ChromiumBrowserConnections.shared.connection(
        machineId: machineId, client: client, resolveBaseURL: resolveBaseURL)
      try Task.checkCancellation()
      guard generation == token else { return }

      try await open(with: connection, token: token)
      ChromiumSpareBrowsers.shared.prepare(machineId: machineId, connection: connection, client: client)
    } catch {
      guard !Task.isCancelled, generation == token else { return }
      readiness.complete(.failure(error))
      pageError = .opening(error.localizedDescription)
      isLoading = false
    }
  }

  private func open(with connection: ChromiumBrowserConnection, token: UUID) async throws {
    if let spare = ChromiumSpareBrowsers.shared.take(machineId: machineId, connection: connection)?.view {
      install(spare, token: token)
      cookieSync = ChromiumProfiles.shared.cookieSync(machineId: machineId)
      try await openFirstPage(in: spare, token: token)
      return
    }
    let address = opensBeforeCookieSync ? firstPage.immediateAddress(current: url) : nil
    firstPage.opening = address
    install(connection.makeView(machineId: machineId, address: address ?? "about:blank"), token: token)
  }

  private func install(_ view: CVChromiumView, token: UUID) {
    hasShownPage = false
    wireView(view, token: token)
    webView = view
    ChromiumAutomationBridge.shared.register(self)
    if needsBackgroundHost { backgroundHost.host(view) }
  }

  private func openFirstPage(in view: CVChromiumView, token: UUID) async throws {
    if cookieSync?.isCurrent == true {
      let address = await firstPage.address(current: url)
      guard generation == token else { return }
      view.navigate(address)
      pageOpened(view, token: token)
      return
    }
    async let address = firstPage.address(current: url)
    try await cookieSync?.synchronize()
    let target = await address
    guard generation == token else { return }
    view.navigate(target)
    markReady(view)
  }

  private func continueOpening(_ view: CVChromiumView, from opened: String, token: UUID) {
    firstPage.opening = nil
    if firstPage.followsUser, let wanted = url?.absoluteString, wanted != opened { view.navigate(wanted) }
    pageOpened(view, token: token)
  }

  private func pageOpened(_ view: CVChromiumView, token: UUID) {
    markReady(view)
    let loaded = cookieSync?.generation ?? 0
    Task { [weak self] in
      _ = try? await self?.cookieSync?.synchronize()
      guard let self, generation == token, let current = cookieSync?.generation, current != loaded else { return }
      paneSync.recordLoadedCookies(cookieSync)
      webView?.reload()
    }
  }

  private func markReady(_ view: CVChromiumView) {
    synchronized = true
    firstPage.newTabURL = nil
    paneSync.recordLoadedCookies(cookieSync)
    readiness.complete(.success(view))
    ChromiumAutomationBridge.shared.register(self)
  }

  @ObservationIgnored var onOpenLink: ((String, BrowserLinkDestination, CVChromiumView?) -> Bool)?
  @ObservationIgnored private(set) var browserWindow: ChromiumBrowserWindow?

  func adoptPopup(_ view: CVChromiumView) {
    BrowserPageRetention.shared.touch(self)
    isLoading = true
    firstPage.newTabURL = nil
    hasShownPage = false
    wireView(view, token: generation, adopted: true)
    webView = view
    ChromiumAutomationBridge.shared.register(self)
    backgroundHost.host(view)
  }

  private func wireView(_ view: CVChromiumView, token: UUID, adopted: Bool = false) {
    ChromiumPageEvents.connect(view, to: self, token: token, adopted: adopted)
    ChromiumBrowserConnections.shared.renewCredentials(of: view, machineId: machineId, client: client)
  }

  func isCurrent(_ token: UUID) -> Bool { generation == token }

  func applyState(address: String, title: String, loading: Bool, back: Bool, forward: Bool) {
    if let current = URL(string: address), ["http", "https"].contains(current.scheme) {
      url = current
      hasLoadedPage = true
    }
    self.title = title.isEmpty ? (url?.host ?? "Browser") : title
    browserWindow?.window?.title = self.title
    isLoading = loading
    if loading { paneSync.cancelActivation() }
    if loading, let failed = pageError?.url, failed != address { pageError = nil }
    canGoBack = back
    canGoForward = forward
    guard !loading, let location = BrowserLocation.sharedURL(address) else { return }

    BrowserHistory.shared.record(url: address, title: self.title, profile: machineId)
    paneSync.publish(url: location.absoluteString, title: self.title, cookies: cookieSync) { [weak self] in
      self?.navigated(to: location.absoluteString)
    }
  }

  func pageFailed(code: Int, message: String, address: String, token: UUID) async {
    isLoading = false
    guard webView?.browserIsReady == true else {
      pageError = .opening(message)
      readiness.complete(.failure(ChromiumProtocolError(message)))
      return
    }
    let error = await ChromiumLoadFailure.pageError(
      code: code, description: message, address: address, machine: machineName, client: client)
    guard generation == token else { return }

    restartsOnRetry = ChromiumLoadFailure.restartsBrowser(code: code)
    pageError = error
  }

  func browserBecameReady(_ view: CVChromiumView, token: UUID, adopted: Bool) async {
    cookieSync = ChromiumProfiles.shared.attach(view, machineId: machineId, client: client)
    if adopted { return markReady(view) }
    do {
      if let opened = firstPage.opening {
        continueOpening(view, from: opened, token: token)
      } else {
        try await openFirstPage(in: view, token: token)
      }
    } catch {
      pageError = .opening("Couldn’t synchronize browser state. \(error.localizedDescription)")
      readiness.complete(.failure(error))
    }
  }

  func browserClosed(byPage closedByPage: Bool) {
    guard BrowserPageClosing.shared.closesTab(whenClosedByPage: closedByPage) else { return }
    onClose?()
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

  func updateFavicon(_ png: Data?) {
    favicon = png.flatMap { NSImage(data: $0) }
    guard let png, let page = url.flatMap({ BrowserLocation.sharedURL($0.absoluteString) })?.absoluteString
    else { return }

    favicons.iconLoaded(png: png, page: page)
  }

  private func navigated(to page: String) {
    onNavigate?(page, title)
    favicons.pageLoaded(page)
  }

  func windowClosed() {
    browserWindow = nil
    onClose?()
  }

  func synchronizeCookies() async throws { try await cookieSync?.synchronize() }

  func readyView() async throws -> CVChromiumView {
    needsBackgroundHost = true
    if readiness.failure != nil { resetBrowser(keepingAutomationTarget: true) }
    if let view = webView { backgroundHost.host(view) }
    if let view = webView, view.browserIsReady, synchronized {
      await freezer.thaw()
      return view
    }
    start()
    if let view = webView, view.browserIsReady, synchronized { return view }
    return try await readiness.wait()
  }

  func submitAddress(_ address: String) {
    guard let target = BrowserLocation.addressBarURL(address) else {
      pageError = BrowserPageError(title: "Can’t Open Address", message: "Enter a search term or a web address.")
      return
    }
    firstPage.followsUser = true
    suggestions.dismiss()
    activationTask?.cancel()
    paneSync.cancelActivation()
    url = target
    pageError = nil
    isLoading = true
    if let webView, synchronized { webView.navigate(target.absoluteString) } else { start() }
  }

  func reload(ignoringCache: Bool = false) {
    if pageError != nil, !synchronized || restartsOnRetry { resetBrowser() }
    pageError = nil
    guard let webView else { return start() }
    if ignoringCache { webView.reloadIgnoringCache() } else { webView.reload() }
  }
  func stop() { webView?.stop(); isLoading = false }
  func goBack() {
    guard canGoBack else { return }
    pageError = nil
    webView?.goBack()
  }
  func goForward() {
    guard canGoForward else { return }
    pageError = nil
    webView?.goForward()
  }

  func zoom(_ command: BrowserZoomCommand) {
    guard let webView, webView.browserIsReady else { return }
    switch command {
    case .zoomIn: webView.zoomIn()
    case .zoomOut: webView.zoomOut()
    case .reset: webView.resetZoom()
    }
    pageZoom.present()
  }
  func setVisible(_ visible: Bool) {
    if isVisible != visible { retentionRevision += 1; BrowserPageRetention.shared.touch(self) }
    isVisible = visible
    updateFreezing()
    ChromiumProfiles.shared.setVisible(visible, paneId: paneId, machineId: machineId)
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
  private func updateFreezing() {
    guard let webView else { return }
    guard !isVisible else {
      Task { await freezer.thaw() }
      return
    }
    freezer.freezeLater(webView) { [weak self] in self?.protectsBrowserPage == false }
  }
  func captureSnapshot() async {
    guard let view = webView, view.hasCommittedPage, let image = await ChromiumPageSnapshot.capture(view),
      webView === view
    else { return }
    snapshot = image
  }
  func showDevTools() { webView?.showDevTools() }
  func openAsNewTab(_ address: String? = nil) { firstPage.newTabURL = address ?? url?.absoluteString }
  func teardown() {
    returnToWorkspace()
    isVisible = false
    ChromiumProfiles.shared.setVisible(false, paneId: paneId, machineId: machineId)
    _ = paneSync.setVisible(false)
    BrowserPageRetention.shared.remove(self)
    suggestions.dismiss()
    resetBrowser()
    onNavigate = nil
    favicons.onShare = nil
  }
  private func resetBrowser(keepingAutomationTarget: Bool = false) {
    pageZoom.reset()
    synchronized = false
    readiness.complete(.failure(ChromiumProtocolError("Browser closed")))
    readiness.forgetFailure()
    if !keepingAutomationTarget { ChromiumAutomationBridge.shared.unregister(paneId) }
    activationTask?.cancel()
    generation = UUID()
    loadTask?.cancel()
    loadTask = nil
    freezer.cancel()
    ChromiumProfiles.shared.detach(webView, machineId: machineId)
    webView?.closeBrowser()
    webView?.removeFromSuperview()
    webView = nil
    backgroundHost.close()
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
    if snapshot == nil { await captureSnapshot() }
    let result = try? await view.cdp(
      "Runtime.evaluate", ["expression": BrowserPageActivity.canDiscardScript, "returnByValue": true])
    guard (result?["result"] as? [String: Any])?["value"] as? Bool == true,
      generation == token, retentionRevision == activity, !protectsBrowserPage
    else { return false }
    resetBrowser()
    firstPage.followsUser = false
    return true
  }
}
