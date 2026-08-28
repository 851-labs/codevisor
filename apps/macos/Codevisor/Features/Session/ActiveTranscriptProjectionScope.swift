import ACPKit
import CodevisorCore
import SwiftUI
import TranscriptKit

/// Observes only the token-level active slot, parses it away from MainActor,
/// and leaves the cached settled projection untouched.
struct ActiveTranscriptProjectionScope<Content: View>: View {
    let controller: SessionController
    let projectedRows: [TranscriptVirtualRow]
    let content: ([TranscriptVirtualRow]) -> Content
    @State private var activeRows: [TranscriptVirtualRow] = []

    init(
        controller: SessionController,
        projectedRows: [TranscriptVirtualRow],
        @ViewBuilder content: @escaping ([TranscriptVirtualRow]) -> Content
    ) {
        self.controller = controller
        self.projectedRows = projectedRows
        self.content = content
    }

    var body: some View {
        content(activeRows)
            .task(id: taskKey) {
                guard let projectedItem else {
                    activeRows = []
                    return
                }
                let revision = controller.activeItemRevision
                let item = TranscriptActiveItemResolver.resolve(
                    projected: projectedItem,
                    live: controller.activeItem,
                    settled: controller.settledConversation
                )
                let waiting = controller.waitingBackgroundTaskDescription
                let nextRows = await Task.detached(priority: .userInitiated) {
                    TranscriptActiveRowProjection.rows(
                        for: item,
                        waitingOnBackgroundTask: waiting
                    )
                }.value
                guard !Task.isCancelled,
                    taskKey.revision == revision,
                    taskKey.projectedID == projectedItem.id
                else { return }
                activeRows = nextRows
            }
    }

    private var projectedItem: ConversationItem? {
        projectedRows.lazy.compactMap { row in
            if case let .active(item) = row.content { item } else { nil }
        }.first
    }

    private var taskKey: TaskKey {
        TaskKey(
            revision: controller.activeItemRevision,
            projectedID: projectedItem?.id,
            waitingDescription: controller.waitingBackgroundTaskDescription
        )
    }

    private struct TaskKey: Hashable {
        let revision: UInt64
        let projectedID: UUID?
        let waitingDescription: String?
    }
}
