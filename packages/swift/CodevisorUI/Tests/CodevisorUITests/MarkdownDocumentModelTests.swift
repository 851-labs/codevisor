import Foundation
import Testing
import Observation
import CodevisorTestSupport
@testable import CodevisorUI

@Suite("Markdown document loading", .timeLimit(.minutes(1)))
@MainActor
struct MarkdownDocumentModelTests {
  @Test func fastLoadDoesNotFlashProgress() async throws {
    let reads = ControlledResponse<Data>()
    let delay = ControlledResponse<Void>()
    let document = MarkdownDocumentModel(
      path: "/docs/audit.md", fetch: { try await reads.next() },
      waitForProgress: { try await delay.next() }
    )

    let load = document.refresh()
    try await waitUntil { reads.count == 1 && delay.count == 1 }
    #expect(document.isLoading)
    #expect(!document.showsLoadingProgress)

    let progress = document.progressTask
    reads.succeed(Data("# Audit".utf8))
    await load.value
    #expect(document.content?.text == "# Audit")
    #expect(!document.isLoading)
    #expect(!document.showsLoadingProgress)

    // Even a timer that ignores cancellation cannot show progress afterward.
    delay.succeed(())
    await progress?.value
    #expect(!document.showsLoadingProgress)
  }

  @Test func slowInitialLoadShowsProgressAfterTheDelay() async throws {
    let reads = ControlledResponse<Data>()
    let delay = ControlledResponse<Void>()
    let document = MarkdownDocumentModel(
      path: "/docs/audit.md", fetch: { try await reads.next() },
      waitForProgress: { try await delay.next() }
    )

    let load = document.refresh()
    try await waitUntil { reads.count == 1 && delay.count == 1 }
    #expect(!document.showsLoadingProgress)
    delay.succeed(())
    try await waitUntil { document.showsLoadingProgress }
    #expect(document.content == nil)

    reads.succeed(Data("# Audit".utf8))
    await load.value
    #expect(document.content?.text == "# Audit")
    #expect(!document.showsLoadingProgress)
  }

  @Test func returningToATabKeepsContentVisibleAndSharesTheRefresh() async throws {
    let reads = ControlledResponse<Data>()
    let document = MarkdownDocumentModel(path: "/docs/audit.md", fetch: { try await reads.next() })
    let first = document.refresh()
    try await waitUntil { reads.count == 1 }
    reads.succeed(Data("# Original".utf8))
    await first.value
    document.cancelLoading()

    let refresh = document.refresh()
    let overlappingRefresh = document.refresh()
    try await waitUntil { reads.count == 2 }
    #expect(document.content?.text == "# Original")
    #expect(!document.showsLoadingProgress)

    reads.succeed(Data("# Updated".utf8), request: 1)
    await refresh.value
    await overlappingRefresh.value
    #expect(reads.count == 2)
    #expect(document.content?.text == "# Updated")
    #expect(!document.isLoading)
  }

  @Test func cancelledReadCannotOverwriteANewerLoad() async throws {
    let reads = ControlledResponse<Data>()
    let document = MarkdownDocumentModel(path: "/docs/audit.md", fetch: { try await reads.next() })
    let oldLoad = document.refresh()
    try await waitUntil { reads.count == 1 }
    document.cancelLoading()
    let newLoad = document.refresh()
    try await waitUntil { reads.count == 2 }

    reads.succeed(Data("# Current".utf8), request: 1)
    await newLoad.value
    reads.succeed(Data("# Stale".utf8))
    await oldLoad.value
    #expect(document.content?.text == "# Current")
    #expect(document.failure == nil)
    #expect(!document.isLoading)
    #expect(!document.showsLoadingProgress)
  }

  @Test func leavingDuringRefreshKeepsTheLastSuccessfulContent() async throws {
    let reads = ControlledResponse<Data>()
    let document = MarkdownDocumentModel(path: "/docs/audit.md", fetch: { try await reads.next() })
    let first = document.refresh()
    try await waitUntil { reads.count == 1 }
    reads.succeed(Data("# Original".utf8))
    await first.value

    let refresh = document.refresh()
    try await waitUntil { reads.count == 2 }
    document.cancelLoading()
    reads.fail(URLError(.notConnectedToInternet), request: 1)
    await refresh.value
    #expect(document.content?.text == "# Original")
    #expect(document.failure == nil)
    #expect(!document.isLoading)
  }

  @Test func failedLoadCanBeRetried() async throws {
    let reads = ControlledResponse<Data>()
    let document = MarkdownDocumentModel(path: "/docs/audit.md", fetch: { try await reads.next() })
    let first = document.refresh()
    try await waitUntil { reads.count == 1 }
    reads.fail(URLError(.notConnectedToInternet))
    await first.value
    #expect(document.failure?.title == "Can’t connect to this machine")
    #expect(!document.showsLoadingProgress)

    let retry = document.refresh()
    #expect(document.failure == nil)
    try await waitUntil { reads.count == 2 }
    reads.succeed(Data("# Reconnected".utf8), request: 1)
    await retry.value
    #expect(document.content?.text == "# Reconnected")
    #expect(document.failure == nil)
  }

  private func waitUntil(_ condition: () -> Bool) async throws {
    await awaitObserved(condition)
  }
}

/// Intentionally ignores cancellation, as a remote response can arrive after navigation.
@MainActor
@Observable
private final class ControlledResponse<Value: Sendable> {
  private(set) var count = 0
  private var pending: [Int: CheckedContinuation<Value, any Error>] = [:]

  func next() async throws -> Value {
    let request = count
    count += 1
    return try await withCheckedThrowingContinuation { pending[request] = $0 }
  }

  func succeed(_ value: Value, request: Int = 0) {
    pending.removeValue(forKey: request)?.resume(returning: value)
  }

  func fail(_ error: any Error, request: Int = 0) {
    pending.removeValue(forKey: request)?.resume(throwing: error)
  }
}
