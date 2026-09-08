import CodevisorClient
import Foundation
import Testing
@testable import CodevisorUI

@MainActor
private final class BrowserStateFixture: BrowserStateClienting {
  var revision = 0
  var entries: [String: BrowserCookieEntry] = [:]
  var navigation: BrowserNavigation?
  var publications: [BrowserNavigation] = []
  var sentChanges = 0
  var beforeReply: (() async -> Void)?
  func exchangeBrowserCookies(_ mutations: [BrowserCookieMutation]) async throws -> BrowserCookieSnapshot {
    sentChanges += mutations.count
    for change in mutations where (entries[change.key]?.revision ?? 0) == change.expectedRevision {
      revision += 1
      entries[change.key] = BrowserCookieEntry(key: change.key, revision: revision, cookie: change.cookie)
    }
    let reply = BrowserCookieSnapshot(revision: revision, entries: Array(entries.values))
    if let hook = beforeReply { beforeReply = nil; await hook() }
    return reply
  }
  func browserNavigation(paneId: UUID) async throws -> BrowserNavigation? { navigation }
  func publishBrowserNavigation(paneId: UUID, navigation: BrowserNavigation) async throws {
    publications.append(navigation); self.navigation = navigation
  }
  func change(_ cookie: BrowserCookie?, key: String) {
    revision += 1
    entries[key] = BrowserCookieEntry(key: key, revision: revision, cookie: cookie)
  }
}

@MainActor
@Suite("Browser state synchronization")
struct BrowserStateSyncTests {
  private var cookie: BrowserCookie {
    BrowserCookie(
      name: "session", value: "fixture", domain: "localhost", path: "/", secure: false, httpOnly: true, sameSite: "lax")
  }

  @Test func cookiesMergeWithoutEchoAndLogoutWinsAfterRestart() async throws {
    let server = BrowserStateFixture()
    var local = [cookie.key: cookie]
    let sync = BrowserCookieSync(
      client: server, read: { Array(local.values) },
      apply: { next, previous in
        if let previous { local[previous.key] = nil }; if let next { local[next.key] = next }
      })
    try await sync.synchronize()
    #expect(server.entries[cookie.key]?.cookie == cookie)
    #expect(server.sentChanges == 1)
    try await sync.synchronize()
    #expect(server.sentChanges == 1)
    server.change(nil, key: cookie.key)
    try await sync.synchronize()
    #expect(local.isEmpty)
    // A freshly opened, previously offline profile still carrying the old cookie
    // must consume the deletion instead of seeding another login.
    local[cookie.key] = cookie
    let restarted = BrowserCookieSync(
      client: server, read: { Array(local.values) },
      apply: { next, previous in
        if let previous { local[previous.key] = nil }; if let next { local[next.key] = next }
      })
    try await restarted.synchronize()
    #expect(local.isEmpty)
    #expect(server.sentChanges == 1)
  }

  @Test func aPageCookieChangedDuringAnExchangeIsPublishedNextTime() async throws {
    let server = BrowserStateFixture()
    var local = [cookie.key: cookie]
    let sync = BrowserCookieSync(
      client: server, read: { Array(local.values) },
      apply: { next, previous in
        if let previous { local[previous.key] = nil }; if let next { local[next.key] = next }
      })
    try await sync.synchronize()
    var rotated = cookie; rotated.value = "rotated-fixture"
    server.beforeReply = { local[rotated.key] = rotated }
    try await sync.synchronize()
    #expect(local[cookie.key] == rotated)
    try await sync.synchronize()
    #expect(server.entries[cookie.key]?.cookie == rotated)
  }

  @Test func engineNormalizationDoesNotInvalidateCachedPagesOnEveryExchange() async throws {
    let server = BrowserStateFixture()
    var source = cookie
    source.expires = 10_000_000_000.5
    server.change(source, key: source.key)
    var local: [String: BrowserCookie] = [:]
    let cookies = BrowserCookieSync(
      client: server, read: { Array(local.values) },
      apply: { next, previous in
        if let previous { local[previous.key] = nil }
        if var next {
          next.expires = next.expires.map { $0.rounded(.down) }
          local[next.key] = next
        }
      })
    try await cookies.synchronize()
    let loadedGeneration = cookies.generation
    try await cookies.synchronize()
    #expect(cookies.generation == loadedGeneration)
    #expect(server.sentChanges == 0)
  }

  @Test func bootstrapDoesNotOverwriteANewLoginWhileTheServerReplies() async throws {
    let server = BrowserStateFixture()
    server.change(cookie, key: cookie.key)
    var local = [cookie.key: cookie]
    var rotated = cookie; rotated.value = "new-login"
    server.beforeReply = { local[rotated.key] = rotated }
    let sync = BrowserCookieSync(
      client: server, read: { Array(local.values) },
      apply: { next, previous in
        if let previous { local[previous.key] = nil }; if let next { local[next.key] = next }
      })
    try await sync.synchronize()
    #expect(local[cookie.key] == rotated)
    #expect(server.entries[cookie.key]?.cookie == rotated)
  }

  @Test func navigationOnlyAdoptsOnPaneEntryAndCookiesArriveBeforeLoad() async throws {
    let server = BrowserStateFixture()
    let sync = BrowserPaneSync(paneId: UUID(), client: server)
    var local: [String: BrowserCookie] = [:]
    let cookies = BrowserCookieSync(
      client: server, read: { Array(local.values) },
      apply: { next, _ in
        if let next { local[next.key] = next }
      })
    server.navigation = BrowserNavigation(url: "https://example.test/first", title: "First")
    var loads: [String] = []
    #expect(sync.setVisible(true))
    await sync.activate(cookies: cookies, currentURL: nil, fallbackURL: nil) { url, _ in loads.append(url) }
    server.navigation = BrowserNavigation(url: "https://example.test/second", title: "Second")
    #expect(!sync.setVisible(true))
    #expect(loads == ["https://example.test/first"])
    #expect(!sync.setVisible(false))
    #expect(sync.setVisible(true))
    server.change(cookie, key: cookie.key)
    await sync.activate(cookies: cookies, currentURL: "https://example.test/first", fallbackURL: nil) { url, _ in
      #expect(local[cookie.key] == cookie)
      loads.append(url)
    }
    #expect(loads.last == "https://example.test/second")
    #expect(server.publications.isEmpty)
  }

  @Test func inFlightActivationDoesNotNavigateAfterLeaving() async throws {
    let server = BrowserStateFixture()
    let pane = BrowserPaneSync(paneId: UUID(), client: server)
    let cookies = BrowserCookieSync(client: server, read: { [] }, apply: { _, _ in })
    server.navigation = BrowserNavigation(url: "https://example.test", title: "Page")
    server.beforeReply = { _ = pane.setVisible(false) }
    _ = pane.setVisible(true)
    var loaded = false
    await pane.activate(cookies: cookies, currentURL: nil, fallbackURL: nil) { _, _ in loaded = true }
    #expect(!loaded)
  }

  @Test func localNavigationWinsOverADelayedPaneEntryReply() async {
    let server = BrowserStateFixture()
    let pane = BrowserPaneSync(paneId: UUID(), client: server)
    let cookies = BrowserCookieSync(client: server, read: { [] }, apply: { _, _ in })
    server.navigation = BrowserNavigation(url: "https://example.test/old", title: "Old")
    // The local page starts navigating while its activation exchange is pending.
    server.beforeReply = { pane.cancelActivation() }
    _ = pane.setVisible(true)
    var loaded = false
    await pane.activate(cookies: cookies, currentURL: "https://example.test/new", fallbackURL: nil) { _, _ in
      loaded = true
    }
    #expect(!loaded)
  }

  @Test func openingAnAlreadyLoadedBackgroundPaneOnlyReloadsForNewCookies() async throws {
    let server = BrowserStateFixture()
    let pane = BrowserPaneSync(paneId: UUID(), client: server)
    var local: [String: BrowserCookie] = [:]
    let cookies = BrowserCookieSync(
      client: server, read: { Array(local.values) },
      apply: { next, previous in
        if let previous { local[previous.key] = nil }
        if let next { local[next.key] = next }
      })
    let url = "https://example.test/background"
    server.navigation = BrowserNavigation(url: url, title: "Background")
    server.change(cookie, key: cookie.key)
    try await cookies.synchronize()
    #expect(cookies.generation > 0)
    pane.recordLoadedCookies(cookies)

    var loads: [String] = []
    #expect(pane.setVisible(true))
    await pane.activate(cookies: cookies, currentURL: url, fallbackURL: nil) { url, _ in loads.append(url) }
    #expect(loads.isEmpty)

    // A later login from another client must still refresh on pane entry.
    #expect(!pane.setVisible(false))
    var rotated = cookie
    rotated.value = "updated-login"
    server.change(rotated, key: cookie.key)
    #expect(pane.setVisible(true))
    await pane.activate(cookies: cookies, currentURL: url, fallbackURL: nil) { url, reload in
      #expect(reload)
      #expect(local[cookie.key] == rotated)
      loads.append(url)
    }
    #expect(loads == [url])
  }
}
