import ACPKit
import CodevisorCore
import CodevisorUI
import SwiftUI

/// The only transcript subtree that observes token-level active-item changes.
/// Its host asks the native virtualizer to remeasure without rebuilding the
/// settled row list.
struct TranscriptActiveItemView: View {
    let controller: SessionController
    @Environment(\.transcriptInvalidateRowMeasurement) private var invalidateRowMeasurement

    var body: some View {
        let revision = controller.activeItemRevision
        let waitingOnBackgroundTask = controller.waitingBackgroundTaskDescription
        let connectionRecoveryMessage = controller.connectionRecoveryMessage
        let goal = controller.model?.goal
        let goalActivity = goal?.status == .active ? goal?.activity : nil
        if let item = controller.activeItem {
            ConversationItemRow(
                item: item,
                isWaitingOnUser: controller.pendingQuestion != nil,
                waitingOnBackgroundTask: waitingOnBackgroundTask,
                goalActivity: goalActivity
            )
            .environment(
                \.runningSubagentToolCallIds,
                controller.runningSubagentToolCallIds
            )
            .id(item.id)
            .onChange(of: revision, initial: true) { _, _ in
                invalidateRowMeasurement?()
            }
            .onChange(of: waitingOnBackgroundTask) { _, _ in
                invalidateRowMeasurement?()
            }
            .onChange(of: connectionRecoveryMessage) { _, _ in
                invalidateRowMeasurement?()
            }
            .onChange(of: goalActivity) { _, _ in
                invalidateRowMeasurement?()
            }
        }
    }
}
