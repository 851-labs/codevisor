import CodevisorClient
import Foundation

@MainActor
public final class BrowserPaneSync {
  public static let quickReturnInterval: TimeInterval = 30
  private let paneId: UUID
  private let client: any BrowserStateClienting
  private let now: () -> TimeInterval
  private var publication: Task<Void, Never>?
  private var lastPublished: BrowserNavigation?
  private var visible = false
  private var activation = 0
  private var cookieGeneration = 0
  private var hiddenAt: TimeInterval?
  private var refreshesFromServer = true

  public init(
    paneId: UUID, client: any BrowserStateClienting,
    now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
  ) {
    self.paneId = paneId
    self.client = client
    self.now = now
  }

  public func recordLoadedCookies(_ cookies: BrowserCookieSync?) {
    cookieGeneration = cookies?.generation ?? 0
  }

  public func setVisible(_ value: Bool) -> Bool {
    guard visible != value else { return false }
    visible = value; activation += 1
    if value { refreshesFromServer = !isQuickReturn } else { hiddenAt = now() }
    return value
  }
  public func cancelActivation() { activation += 1 }
  public func activate(
    cookies: BrowserCookieSync?, currentURL: String?, fallbackURL: String?,
    load: @escaping @MainActor (String, Bool) -> Void
  ) async {
    let token = activation
    await publication?.value
    guard refreshesFromServer else {
      if visible, activation == token { reloadForNewCookies(cookies, currentURL: currentURL, load: load) }
      return
    }
    do {
      try await cookies?.synchronize()
      let navigation = try await client.browserNavigation(paneId: paneId)
      guard visible, activation == token else { return }
      let target = navigation?.url ?? fallbackURL
      let changedCookies = cookieGeneration != (cookies?.generation ?? 0)
      cookieGeneration = cookies?.generation ?? 0
      if let target, target != currentURL || changedCookies {
        lastPublished = navigation
        load(target, target == currentURL)
      }
    } catch {
      if currentURL == nil, let fallbackURL, visible, activation == token { load(fallbackURL, false) }
    }
  }
  public func publish(url: String, title: String, cookies: BrowserCookieSync?, then: @escaping @MainActor () -> Void) {
    guard let target = BrowserLocation.sharedURL(url) else { return }
    let navigation = BrowserNavigation(url: target.absoluteString, title: title)
    guard navigation != lastPublished else { return }
    lastPublished = navigation
    let previous = publication
    publication = Task {
      await previous?.value
      do {
        try await cookies?.synchronize()
        try await client.publishBrowserNavigation(paneId: paneId, navigation: navigation)
        then()
      } catch { if lastPublished == navigation { lastPublished = nil } }
    }
  }

  private var isQuickReturn: Bool {
    guard let hiddenAt else { return false }
    return now() - hiddenAt < Self.quickReturnInterval
  }

  private func reloadForNewCookies(
    _ cookies: BrowserCookieSync?, currentURL: String?, load: @MainActor (String, Bool) -> Void
  ) {
    let generation = cookies?.generation ?? 0
    guard generation != cookieGeneration, let currentURL else { return }
    cookieGeneration = generation
    load(currentURL, true)
  }
}
