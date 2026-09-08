import CodevisorTestSupport
import Foundation
import Testing
@testable import CodevisorUI

@MainActor
@Suite("Browser address suggestions")
struct BrowserSuggestionsTests {
  @Test func localHistoryCompletesAndStaysInsideItsProfile() {
    let history = BrowserHistory(defaults: nil)
    history.record(url: "https://www.emojis.com/search", title: "Emoji search", profile: "local")
    history.record(url: "https://private.example/", title: "Private", profile: "remote")
    history.record(url: "https://example.com/callback?code=secret", title: "Login", profile: "local")
    let suggestions = BrowserSuggestions(profile: "local", history: history, fetch: { _ in [] })
    suggestions.update("emo")
    #expect(suggestions.inlineCompletion == "emojis.com")
    #expect(suggestions.selected?.value == "https://www.emojis.com/")
    suggestions.dismiss()
    suggestions.update("private")
    #expect(suggestions.items.allSatisfy { $0.kind == .search })
    #expect(history.visits(profile: "local").count == 1)
    suggestions.dismiss()
  }

  @Test func typingAnOriginDoesNotReplayAnOldSearchOrPath() {
    let history = BrowserHistory(defaults: nil)
    history.record(url: "https://www.google.com/search?q=previous", title: "Search", profile: "test")
    let suggestions = BrowserSuggestions(profile: "test", history: history, fetch: { _ in [] })
    suggestions.update("https://www.google.com/")
    #expect(suggestions.inlineCompletion == nil)
    #expect(suggestions.selected == nil)
    suggestions.update("https://www.google.com/sea")
    #expect(suggestions.inlineCompletion == "https://www.google.com/search?q=previous")
    suggestions.dismiss()
  }

  @Test(arguments: [
    "localhost", "localhost:3000", "127.0.0.1", "devbox:3000", "https://example.com", "example.com/path?key=secret",
    "alice@example.com", "site.test",
  ])
  func addressesNeverGoToGoogle(input: String) {
    #expect(!BrowserSuggestions.allowsRemoteSuggestions(input))
  }

  @Test func debounceOnlyRequestsTheLatestInput() async throws {
    let clock = TestClock()
    var requested: [String] = []
    let suggestions = BrowserSuggestions(
      profile: "fixture", history: BrowserHistory(defaults: nil),
      fetch: { query in
        requested.append(query); return [query, "swiftui", "swift tutorial"]
      },
      sleep: { try await clock.sleep(for: .milliseconds(180)) })
    let first = suggestions.update("s")
    await clock.waitForSleep(.milliseconds(180))
    let second = suggestions.update("swift")
    await clock.waitForSleep(.milliseconds(180), count: 2)
    clock.advance(by: .milliseconds(179))
    #expect(requested.isEmpty)
    clock.advance(by: .milliseconds(1))
    await first?.value
    await second?.value
    #expect(requested == ["swift"])
    #expect(suggestions.items.map(\.value) == ["swift", "swiftui", "swift tutorial"])
    suggestions.moveSelection(1)
    suggestions.moveSelection(1)
    #expect(suggestions.selected?.value == "swiftui")
    suggestions.dismiss()
    #expect(suggestions.items.isEmpty)
  }

  @Test func aStaleNetworkReplyCannotReplaceNewerResults() async {
    let entered = TestSignal()
    let release = TestSignal()
    let suggestions = BrowserSuggestions(
      profile: "fixture", history: BrowserHistory(defaults: nil),
      fetch: { query in
        if query == "old" { entered.signal(); await release.wait() }
        return ["\(query) result"]
      }, sleep: {})
    let old = suggestions.update("old")
    await entered.wait()
    await suggestions.update("new")?.value
    release.signal()
    await old?.value
    #expect(suggestions.items.map(\.value) == ["new", "new result"])
    suggestions.dismiss()
  }
}
