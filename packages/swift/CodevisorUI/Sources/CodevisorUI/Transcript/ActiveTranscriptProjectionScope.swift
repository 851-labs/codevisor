import CodevisorCore
import SwiftUI
import TranscriptKit

/// Observes only the token-level active slot, parses it away from MainActor,
/// and leaves the cached settled projection untouched.
public struct ActiveTranscriptProjectionScope<Content: View>: View {
    private let controller: SessionController
    private let projectedRows: [TranscriptPresentationRow]
    private let content: ([TranscriptPresentationRow], UInt64, Bool) -> Content
    @State private var activeRows: [TranscriptPresentationRow] = []
    @State private var activeRowsVersion: UInt64 = 0
    @State private var publishedProjectionKey: TaskKey?
    @State private var projectionStaging = ProjectionStaging()
    @State private var projectionWorker = TranscriptActiveProjectionWorker()

    public init(
        controller: SessionController,
        projectedRows: [TranscriptPresentationRow],
        @ViewBuilder content: @escaping ([TranscriptPresentationRow], UInt64, Bool) -> Content
    ) {
        self.controller = controller
        self.projectedRows = projectedRows
        self.content = content
    }

    public var body: some View {
        let presentationFrame = controller.transcriptPresentationFrameRevision
        let projectionKey = taskKey
        let isActiveProjectionPending =
            projectedItem != nil
            && publishedProjectionKey != projectionKey
        content(activeRows, activeRowsVersion, isActiveProjectionPending)
            .task(id: taskKey) {
                guard let projectedItem else {
                    projectionWorker.cancel()
                    projectionStaging.ready = ReadyProjection(key: taskKey, rows: [])
                    controller.requestTranscriptPresentationFrame()
                    return
                }
                let key = taskKey
                let item = TranscriptActiveItemResolver.resolve(
                    projected: projectedItem,
                    live: controller.activeItem,
                    settled: controller.settledConversation
                )
                let waiting = controller.waitingBackgroundTaskDescription
                projectionWorker.submit(
                    .init(
                        revision: key.revision,
                        projectedID: projectedItem.id,
                        item: item,
                        waitingOnBackgroundTask: waiting
                    )
                ) { output in
                    projectionStaging.ready = ReadyProjection(key: key, rows: output.rows)
                    controller.requestTranscriptPresentationFrame()
                }
            }
            .onChange(of: presentationFrame, initial: true) { _, _ in
                publishReadyProjection()
            }
            .onDisappear {
                projectionWorker.cancel()
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

        /// A projection prepared for the current assistant remains safe to
        /// present when a newer token batch lands on the same display frame.
        /// Requiring exact revision equality starves publication on a steady
        /// stream: every frame advances the model just before SwiftUI gets to
        /// publish the rows prepared for the preceding frame.
        func canPublish(over current: Self) -> Bool {
            projectedID == current.projectedID
                && waitingDescription == current.waitingDescription
                && revision <= current.revision
        }
    }

    private struct ReadyProjection {
        let key: TaskKey
        let rows: [TranscriptPresentationRow]
    }

    @MainActor
    private final class ProjectionStaging {
        var ready: ReadyProjection?
    }

    private func publishReadyProjection() {
        guard let readyProjection = projectionStaging.ready,
            readyProjection.key.canPublish(over: taskKey)
        else { return }
        projectionStaging.ready = nil
        activeRows = readyProjection.rows
        activeRowsVersion &+= 1
        publishedProjectionKey = readyProjection.key
    }
}
