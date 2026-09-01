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
            activeItem: .assistant(message),
            runningSubagentToolCallIDs: []
        )
        #expect(initiallyExpanded.rows.contains(where: isWorkedContent))

        store.setExpanded(.turn(messageID), false)
        let collapsed = TranscriptWorkedRowsVisibility.present(
            rows,
            disclosure: store,
            activeItem: .assistant(message),
            runningSubagentToolCallIDs: []
        )

        #expect(collapsed.rows.contains { $0.id == .assistantWorkedHeader(messageID, .planning) })
        #expect(!collapsed.rows.contains(where: isWorkedContent))
        #expect(collapsed.revisionToken != initiallyExpanded.revisionToken)
    }

    private func isWorkedContent(_ row: TranscriptPresentationRow) -> Bool {
        row.workedSection?.role == .content
    }
}
