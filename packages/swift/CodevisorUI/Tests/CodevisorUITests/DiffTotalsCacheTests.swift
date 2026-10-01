import ACPKit
import CodevisorTestSupport
import Testing
import TranscriptKit

@testable import CodevisorUI

@MainActor
@Suite("DiffTotalsCache")
struct DiffTotalsCacheTests {
  private func edit(_ newText: String, status: ToolCallStatus = .inProgress) -> ToolCall {
    ToolCall(
      toolCallId: "edit", title: "Edit", kind: .edit, status: status,
      content: [.diff(path: "/a.swift", oldText: "one\ntwo\n", newText: newText)])
  }

  @Test("A row's content-diff counter is computed off the render path and delivered when ready")
  func contentTotalsArriveAfterRender() async {
    let cache = DiffTotalsCache()
    let first = edit("one\nthree\nfour\n")
    // Rendering never runs the diff: the first render has no counter yet.
    #expect(cache.totals(for: first) == nil)
    await awaitObserved { cache.totals(for: first) != nil }
    #expect(cache.totals(for: first) == LineDiff.Totals(added: 2, removed: 1))

    // A streamed edit keeps the previous counter until its own diff lands.
    let grown = edit("one\nthree\nfour\nfive\n")
    #expect(cache.totals(for: grown) == LineDiff.Totals(added: 2, removed: 1))
    await awaitObserved { cache.totals(for: grown) == LineDiff.Totals(added: 3, removed: 1) }
  }

  @Test("A remounted row finds its settled counter without diffing again")
  func settledTotalsSurviveRemount() async {
    let settled = edit("one\ntwo\nthree\n", status: .completed)
    let first = DiffTotalsCache()
    _ = first.totals(for: settled)
    await awaitObserved { first.totals(for: settled) != nil }

    let remounted = DiffTotalsCache()
    #expect(remounted.totals(for: settled) == LineDiff.Totals(added: 1, removed: 0))
  }
}
