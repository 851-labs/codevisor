import ACPKit
import CodevisorCore
import Foundation
import Testing
import TranscriptKit
@testable import CodevisorUI

@MainActor
struct TranscriptEarlierHistoryCollapseTargetTests {
  @Test("Revealed earlier steps are collapsible from any visible row of their section")
  func collapsibleSection() {
    let messageID = UUID()
    func text(_ id: String) -> TranscriptEntry { .text(id: id, markdown: "Step \(id)") }
    func tool(_ id: String) -> TranscriptEntry {
      .tool(ToolCall(toolCallId: id, title: "Ran \(id)", kind: .execute, status: .completed))
    }
    let message = AssistantMessage(
      id: messageID,
      turn: AssistantTurn(
        entries: [text("a"), tool("1"), text("b"), tool("2"), text("c"), tool("3"), text("d"), tool("4")],
        isGenerating: true,
        textPhases: ["a": .commentary, "b": .commentary, "c": .commentary, "d": .commentary]
      )
    )
    let section = TranscriptWorkedSectionIdentity(messageID: messageID, kind: .planning)
    let store = TranscriptDisclosureStore()
    func target(rowsMatching role: TranscriptWorkedSectionRowRole) -> TranscriptWorkedSectionIdentity? {
      let rows = TranscriptWorkedRowsVisibility.present(
        TranscriptActiveRowProjection.rows(for: .assistant(message)),
        disclosure: store,
        activeItem: .assistant(message)
      ).rows
      let layout = VirtualTranscriptLayout(
        items: rows.map { .init(key: $0.layoutKey, estimatedHeight: 20) },
        measuredHeights: [:],
        spacing: 0
      )
      let rowByKey = Dictionary(uniqueKeysWithValues: rows.map { ($0.layoutKey, $0) })
      guard let index = rows.lastIndex(where: { $0.workedSection?.role == role }) else { return nil }
      let frame = layout.frame(at: index)
      return TranscriptEarlierHistoryCollapseTarget.section(
        in: layout, rowByKey: rowByKey, viewportTop: frame.minY, viewportBottom: frame.maxY)
    }

    #expect(target(rowsMatching: .content) == nil)

    store.setExpanded(.turnEarlierHistory(messageID), true)
    #expect(target(rowsMatching: .content) == section)
    #expect(target(rowsMatching: .earlierHistory) == section)
  }
}
