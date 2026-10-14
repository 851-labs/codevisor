import CodevisorClient
import Foundation

@MainActor
public final class BrowserPaneSync {
  private let paneId: UUID
  private let client: any BrowserStateClienting
  private var publication: Task<Void, Never>?
  private var lastPublished: BrowserNavigation?
  private var visible = false
  private var activation = 0
  private var cookieGeneration = 0
  public init(paneId: UUID, client: any BrowserStateClienting) { self.paneId = paneId; self.client = client }

  public func recordLoadedCookies(_ cookies: BrowserCookieSync?) {
    cookieGeneration = cookies?.generation ?? 0
  }

  public func setVisible(_ value: Bool) -> Bool {
    guard visible != value else { return false }
    visible = value; activation += 1
    return value
  }
  public func cancelActivation() { activation += 1 }
  public func activate(
    cookies: BrowserCookieSync?, currentURL: String?, fallbackURL: String?,
    load: @escaping @MainActor (String, Bool) -> Void
  ) async {
    let token = activation
    await publication?.value
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
}
