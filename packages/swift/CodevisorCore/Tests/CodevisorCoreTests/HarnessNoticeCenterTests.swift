import CodevisorClient
import Foundation
import Testing

@testable import CodevisorCore

@MainActor
struct HarnessNoticeCenterTests {
  private let message =
    "Claude is now signed in through Codevisor on all your machines. Claude Code on this Mac was signed out."

  @Test func showsEachServerNoticeOnceAcrossRelaunches() throws {
    let preferences = ClientPreferences()
    let reporter = ErrorReporter()
    let notices = [try #require(try harness(notice: ["id": "takeover-1", "message": message]).auth?.notice)]

    HarnessNoticeCenter(preferences: preferences, reporter: reporter).show(notices)
    HarnessNoticeCenter(preferences: preferences, reporter: reporter).show(notices)

    #expect(reporter.entries.map(\.title) == [message])
    #expect(reporter.entries.map(\.kind) == [.notice])
  }

  private func harness(notice: [String: Any]) throws -> ServerHarness {
    let value: [String: Any] = [
      "id": "claude-code", "name": "Claude Code", "symbolName": "terminal", "source": "builtin",
      "launchKind": "executable", "enabled": true, "readiness": ["state": "ready"],
      "auth": [
        "state": "authenticated", "accounts": [], "loginMethods": [], "supportsMultipleAccounts": true,
        "notice": notice,
      ],
    ]
    return try JSONDecoder().decode(ServerHarness.self, from: JSONSerialization.data(withJSONObject: value))
  }
}
