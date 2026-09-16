import CodevisorClient
import CodevisorTestSupport
import Foundation
import Testing

@testable import CodevisorUI

@MainActor struct FileExplorerSearchTests {
  private func result(_ name: String) throws -> ServerFileSearch {
    let data = try JSONSerialization.data(withJSONObject: [
      "path": "/project", "truncated": false, "skippedDirectories": 0,
      "entries": [
        ["name": name, "path": "/project/Configuration/" + name, "isDirectory": false, "isSymbolicLink": false]
      ],
    ])
    return try JSONDecoder().decode(ServerFileSearch.self, from: data)
  }

  @Test func lateResponseCannotReplaceNewQuery() async throws {
    let search = FileExplorerSearch()
    let entered = TestSignal()
    let release = TestSignal()
    let old = try result("old.json")
    let latest = try result("settings.json")
    let first = Task {
      await search.update(query: "old", debounce: {}) { _ in
        entered.signal()
        await release.wait()
        return old
      }
    }
    await entered.wait()
    await search.update(query: "settings", debounce: {}) { _ in latest }
    release.signal()
    await first.value
    #expect(search.result?.entries.first?.name == "settings.json")
    #expect(!search.isSearching)
  }

  @Test func clearingSearchDiscardsPendingResults() async throws {
    let search = FileExplorerSearch()
    let entered = TestSignal()
    let release = TestSignal()
    let response = try result("settings.json")
    let pending = Task {
      await search.update(query: "settings", debounce: {}) { _ in
        entered.signal()
        await release.wait()
        return response
      }
    }
    await entered.wait()
    await search.update(query: "", debounce: {}) { _ in
      Issue.record("An empty query must not search the server")
      return response
    }
    release.signal()
    await pending.value
    #expect(search.result == nil)
    #expect(search.query.isEmpty)
    #expect(!search.isSearching)
  }

  @Test func cancellationDiscardsResponse() async throws {
    let search = FileExplorerSearch()
    let entered = TestSignal()
    let release = TestSignal()
    let response = try result("settings.json")
    let pending = Task {
      await search.update(query: "settings", debounce: {}) { _ in
        entered.signal()
        await release.wait()
        return response
      }
    }
    await entered.wait()
    pending.cancel()
    release.signal()
    await pending.value
    #expect(search.result == nil)
    #expect(search.error == nil)
    #expect(!search.isSearching)
  }
}
