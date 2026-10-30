import ACPKit
import Foundation
import Testing

@testable import TranscriptKit

@Suite("Worked item location of a tool call")
struct TranscriptWorkedItemLocationTests {
  private func tool(_ id: String, _ kind: ToolKind = .execute) -> TranscriptEntry {
    .tool(ToolCall(toolCallId: id, title: "Tool \(id)", kind: kind))
  }

  private func assistant(_ turn: AssistantTurn) -> (AssistantMessage, ConversationItem) {
    let message = AssistantMessage(turn: turn)
    return (message, .assistant(message))
  }

  @Test("Finds the tool group holding the call and the group to expand")
  func toolGroup() {
    let (message, item) = assistant(
      AssistantTurn(entries: [tool("a"), tool("b"), .text(id: "final", markdown: "done")]))

    let location = TranscriptWorkedItemLocation.of(toolCall: "b", in: [item])

    #expect(
      location
        == TranscriptWorkedItemLocation(
          reference: TranscriptWorkedItemReference(messageID: message.id, section: .planning, itemID: "wgroup:a"),
          isEarlierHistory: false,
          toolGroupID: "a"
        ))
  }

  @Test("A call after the plan boundary is in the implementation section")
  func implementationSection() {
    var turn = AssistantTurn(entries: [tool("explore")])
    turn.planBoundary = turn.entries.count
    turn.entries += [tool("impl"), .text(id: "final", markdown: "done")]
    let (message, item) = assistant(turn)

    let location = TranscriptWorkedItemLocation.of(toolCall: "impl", in: [item])

    #expect(location?.section == TranscriptWorkedSectionIdentity(messageID: message.id, kind: .implementation))
  }

  @Test("A call before the three most recent text lines is in earlier history")
  func earlierHistory() {
    let entries: [TranscriptEntry] = [
      tool("old"), .text(id: "t1", markdown: "one"), .text(id: "t2", markdown: "two"),
      .text(id: "t3", markdown: "three"), tool("new"), .text(id: "final", markdown: "done"),
    ]
    let (_, item) = assistant(AssistantTurn(entries: entries))

    #expect(TranscriptWorkedItemLocation.of(toolCall: "old", in: [item])?.isEarlierHistory == true)
    #expect(TranscriptWorkedItemLocation.of(toolCall: "new", in: [item])?.isEarlierHistory == false)
  }

  @Test("A subagent call has no tool group to expand")
  func subagent() {
    let agent = ToolCall(toolCallId: "agent", title: "Agent", kind: .agent, rawInput: .object([:]))
    let (_, item) = assistant(AssistantTurn(entries: [.tool(agent), .text(id: "final", markdown: "done")]))

    let location = TranscriptWorkedItemLocation.of(toolCall: "agent", in: [item])

    #expect(location?.reference.itemID == "wagent:agent")
    #expect(location?.toolGroupID == nil)
  }

  @Test("An unknown call has no location")
  func unknown() {
    let (_, item) = assistant(AssistantTurn(entries: [tool("a"), .text(id: "final", markdown: "done")]))

    #expect(TranscriptWorkedItemLocation.of(toolCall: "missing", in: [item]) == nil)
  }
}
