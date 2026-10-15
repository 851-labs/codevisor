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

  private func isWorkedContent(_ row: TranscriptPresentationRow) -> Bool {
    row.workedSection?.role == .content
  }
}
