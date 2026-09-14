import ACPKit
import CodevisorCore
import Testing
import TranscriptKit
@testable import CodevisorUI

@MainActor
struct ToolGroupHeaderPresentationTests {
  @Test("Collapsed live labels track appended calls and streamed title updates")
  func liveLabelUpdates() {
    let store = TranscriptDisclosureStore()
    let cache = DiffTotalsCache()
    let first = ToolCall(toolCallId: "first", title: "Read README.md", kind: .read, status: .completed)
    var latest = ToolCall(toolCallId: "latest", title: "Running checks", kind: .execute, status: .inProgress)
    var group = ToolCallGroup(calls: [first, latest])

    func header() -> ToolGroupHeaderPresentation {
      ToolGroupHeaderPresentation(
        group: group,
        isExpanded: store.toolGroupDisclosure(id: group.id).isExpanded,
        isTurnActive: true,
        totalsCache: cache
      )
    }

    #expect(header().title == "Running checks")
    #expect(header().isShimmering)
    latest.title = "Running transcript tests"
    group = ToolCallGroup(calls: [first, latest])
    #expect(header().title == "Running transcript tests")

    group = ToolCallGroup(calls: [
      first, latest,
      ToolCall(toolCallId: "next", title: "Reading test results", kind: .read, status: .pending),
    ])
    #expect(header().title == "Reading test results")
    #expect(header().isShimmering)
    #expect(!store.toolGroupDisclosure(id: group.id).isExpanded)
  }

  @Test("Opening live work shows a static summary and preserves the user's choice after completion")
  func manualExpansionDuringActivity() {
    let store = TranscriptDisclosureStore()
    let cache = DiffTotalsCache()
    var call = ToolCall(toolCallId: "call", title: "Checking transcript", kind: .execute, status: .inProgress)
    let disclosure = store.toolGroupDisclosure(id: call.toolCallId)
    disclosure.userToggled()
    let expanded = ToolGroupHeaderPresentation(
      group: ToolCallGroup(calls: [call]), isExpanded: disclosure.isExpanded, isTurnActive: true, totalsCache: cache
    )
    #expect(expanded.title == "Ran a command")
    #expect(!expanded.isShimmering)

    call.status = .completed
    let remounted = store.toolGroupDisclosure(id: call.toolCallId)
    #expect(remounted.isExpanded)
    remounted.userToggled()
    let finished = ToolGroupHeaderPresentation(
      group: ToolCallGroup(calls: [call]), isExpanded: remounted.isExpanded, isTurnActive: true, totalsCache: cache
    )
    #expect(finished.title == "Ran a command")
    #expect(!finished.isShimmering)

    call.status = .inProgress
    let resumed = ToolGroupHeaderPresentation(
      group: ToolCallGroup(calls: [call]), isExpanded: remounted.isExpanded, isTurnActive: true, totalsCache: cache
    )
    #expect(!remounted.isExpanded)
    #expect(resumed.title == "Checking transcript")
    #expect(resumed.isShimmering)
  }

  @Test("A finished latest call keeps its label while earlier work is still running")
  func concurrentCalls() {
    let group = ToolCallGroup(calls: [
      ToolCall(toolCallId: "first", title: "Running tests", kind: .execute, status: .inProgress),
      ToolCall(toolCallId: "last", title: "Read README.md", kind: .read, status: .completed),
    ])
    let header = ToolGroupHeaderPresentation(
      group: group, isExpanded: false, isTurnActive: true, totalsCache: DiffTotalsCache()
    )
    #expect(header.title == "Read README.md")
    #expect(header.isShimmering)
  }

  @Test("All terminal statuses restore the summary", arguments: [ToolCallStatus.completed, .failed, .cancelled])
  func settledGroups(status: ToolCallStatus) {
    let group = ToolCallGroup(calls: [
      ToolCall(toolCallId: "call", title: "Checking transcript", kind: .execute, status: status)
    ])
    let header = ToolGroupHeaderPresentation(
      group: group, isExpanded: false, isTurnActive: true, totalsCache: DiffTotalsCache()
    )
    #expect(header.title == "Ran a command")
    #expect(!header.isShimmering)
  }

  @Test("Inactive turns do not show stale tool activity")
  func inactiveTurn() {
    let group = ToolCallGroup(calls: [
      ToolCall(toolCallId: "call", title: "Checking transcript", kind: .execute, status: .inProgress)
    ])
    let header = ToolGroupHeaderPresentation(
      group: group, isExpanded: false, isTurnActive: false, totalsCache: DiffTotalsCache()
    )
    #expect(header.title == "Ran a command")
    #expect(!header.isShimmering)
  }

  @Test("Collapsed groups use the same readable tool labels as expanded calls")
  func displayTitle() {
    let group = ToolCallGroup(calls: [
      ToolCall(toolCallId: "call", title: "mcp__codevisor__execute", status: .inProgress)
    ])
    let header = ToolGroupHeaderPresentation(
      group: group, isExpanded: false, isTurnActive: true, totalsCache: DiffTotalsCache()
    )
    #expect(header.title == "Running an integration workflow…")
  }
}
