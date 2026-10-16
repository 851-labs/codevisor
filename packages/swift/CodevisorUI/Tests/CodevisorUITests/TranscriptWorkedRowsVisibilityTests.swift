import ACPKit
import CodevisorCore
import Foundation
import Testing
import TranscriptKit
@testable import CodevisorUI

@MainActor
struct TranscriptWorkedRowsVisibilityTests {
  @Test("Worked content is removed before virtualization while its header remains")
  func collapsedRows() {
    let messageID = UUID()
    let message = AssistantMessage(
      id: messageID,
      turn: AssistantTurn(
        entries: [
          .text(id: "commentary", markdown: "One\n\nTwo\n\nThree")
        ],
        textPhases: ["commentary": .commentary]
      )
    )
    let rows = TranscriptActiveRowProjection.rows(for: .assistant(message))
    let store = TranscriptDisclosureStore()
    store.setExpanded(.turn(messageID), true)

    let initiallyExpanded = TranscriptWorkedRowsVisibility.present(
      rows,
      disclosure: store,
      activeItem: .assistant(message)
    )
    #expect(initiallyExpanded.rows.contains(where: isWorkedContent))

    store.setExpanded(.turn(messageID), false)
    let collapsed = TranscriptWorkedRowsVisibility.present(
      rows,
      disclosure: store,
      activeItem: .assistant(message)
    )

    #expect(collapsed.rows.contains { $0.id == .assistantWorkedHeader(messageID, .planning) })
    #expect(!collapsed.rows.contains(where: isWorkedContent))
    #expect(collapsed.visibilityRevision != initiallyExpanded.visibilityRevision)
  }

  @Test("A live section stays open until its turn ends, even when its disclosure was collapsed")
  func liveSectionStaysOpen() {
    let messageID = UUID()
    let message = AssistantMessage(
      id: messageID,
      turn: AssistantTurn(
        entries: [
          .text(id: "commentary", markdown: "Checking the code."),
          .tool(ToolCall(toolCallId: "read", title: "Read source", kind: .read, status: .inProgress)),
        ],
        isGenerating: true,
        textPhases: ["commentary": .commentary]
      )
    )
    let rows = TranscriptActiveRowProjection.rows(for: .assistant(message))
    let liveStreams = rows.compactMap { row -> String? in
      guard case let .markdownChunk(chunk) = row.content, row.workedSection?.role == .content else { return nil }
      return chunk.animationStreamID
    }
    #expect(!liveStreams.isEmpty)
    let store = TranscriptDisclosureStore()
    func present() -> TranscriptWorkedRowsPresentation {
      TranscriptWorkedRowsVisibility.present(
        rows, disclosure: store, activeItem: .assistant(message))
    }

    store.setExpanded(.turn(messageID), false)
    #expect(present().rows.contains(where: isWorkedContent))
    #expect(present().hiddenStreamIDs.isEmpty)
  }

  @Test("Only the last three text parts show until earlier history is revealed")
  func earlierHistory() {
    let messageID = UUID()
    func text(_ id: String) -> TranscriptEntry { .text(id: id, markdown: "Note \(id).") }
    func tool(_ id: String) -> TranscriptEntry {
      .tool(ToolCall(toolCallId: id, title: "Ran \(id)", kind: .execute, status: .completed))
    }
    var message = AssistantMessage(
      id: messageID,
      turn: AssistantTurn(
        entries: [text("a"), tool("1"), text("b"), tool("2"), text("c"), tool("3")],
        isGenerating: true,
        textPhases: ["a": .commentary, "b": .commentary, "c": .commentary, "d": .commentary]
      )
    )
    let store = TranscriptDisclosureStore()
    func visibleWorkedIDs() -> [String] {
      TranscriptWorkedRowsVisibility.present(
        TranscriptActiveRowProjection.rows(for: .assistant(message)),
        disclosure: store,
        activeItem: .assistant(message)
      ).rows.compactMap { row in
        guard row.workedSection?.role.isContent == true else { return nil }
        if case let .markdownChunk(chunk) = row.content { return chunk.animationSourceID }
        if case let .activeWorkedItem(reference) = row.content { return reference.itemID }
        return nil
      }
    }

    #expect(visibleWorkedIDs() == ["a", "wgroup:1", "b", "wgroup:2", "c", "wgroup:3"])

    message.turn.entries += [text("d"), tool("4")]
    #expect(visibleWorkedIDs() == [WorkedItem.earlierHistoryLineID, "b", "wgroup:2", "c", "wgroup:3", "d", "wgroup:4"])

    store.setExpanded(.turnEarlierHistory(messageID), true)
    #expect(visibleWorkedIDs() == ["a", "wgroup:1", "b", "wgroup:2", "c", "wgroup:3", "d", "wgroup:4"])
  }

  private func isWorkedContent(_ row: TranscriptPresentationRow) -> Bool {
    row.workedSection?.role == .content
  }
}
