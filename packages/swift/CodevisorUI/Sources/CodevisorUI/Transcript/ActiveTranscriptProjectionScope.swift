import CodevisorCore
import SwiftUI
import TranscriptKit

public struct ActiveTranscriptProjectionScope<Content: View>: View {
  private let controller: SessionController
  private let projectedRows: [TranscriptPresentationRow]
  private let content: ([TranscriptPresentationRow], UInt64, Bool, Bool, String?) -> Content
  @State private var activeRows: [TranscriptPresentationRow] = []
  @State private var activeRowsVersion: UInt64 = 0
  @State private var activeTextRestorationID: String?
  @State private var publishedProjectionKey: TaskKey?
  @State private var projectionStaging = ProjectionStaging()
  @State private var projectionWorker = TranscriptActiveProjectionWorker()
  @State private var framedStaging = ActiveTranscriptProjectionStaging()
  @State private var presentObserver: UUID?

  public init(
    controller: SessionController,
    projectedRows: [TranscriptPresentationRow],
    @ViewBuilder content: @escaping ([TranscriptPresentationRow], UInt64, Bool, Bool, String?) -> Content
  ) {
    self.controller = controller
    self.projectedRows = projectedRows
    self.content = content
  }

  public var body: some View {
    #if os(macOS)
      framedBody
    #else
      legacyBody
    #endif
  }

  private var framedBody: some View {
    let isAwaitingFirstProjection =
      projectedItem != nil && publishedProjectionKey?.projectedID != projectedItem?.id
    return content(
      activeRows, activeRowsVersion, isAwaitingFirstProjection, isAwaitingFirstProjection,
      activeTextRestorationID
    )
    .background {
      ActiveTranscriptProjectionSubmitter(
        controller: controller,
        projectedItem: projectedItem,
        worker: projectionWorker,
        staging: framedStaging
      )
    }
    .onAppear { observePresentedFrames() }
    .onDisappear { stopObservingPresentedFrames() }
  }

  private func observePresentedFrames() {
    guard presentObserver == nil else { return }
    let staging = framedStaging
    let publish = publishFramedProjection
    presentObserver = controller.presentationClock.addPresentObserver {
      guard let ready = staging.takePublishable() else { return }
      publish(ready)
    }
  }

  private func stopObservingPresentedFrames() {
    if let presentObserver { controller.presentationClock.removePresentObserver(presentObserver) }
    presentObserver = nil
    projectionWorker.cancel()
  }

  private func publishFramedProjection(_ ready: ActiveTranscriptReadyProjection) {
    activeRows = ready.rows
    activeTextRestorationID = ready.restorationID
    activeRowsVersion &+= 1
    publishedProjectionKey = TaskKey(
      revision: ready.key.revision,
      projectedID: ready.key.projectedID,
      waitingDescription: ready.key.waitingDescription
    )
  }

  @ViewBuilder
  private var legacyBody: some View {
    let presentationFrame = controller.transcriptPresentationFrameRevision
    let projectionKey = taskKey
    let isActiveProjectionPending =
      projectedItem != nil
      && publishedProjectionKey != projectionKey
    let isAwaitingFirstActiveProjection =
      projectedItem != nil
      && publishedProjectionKey?.projectedID != projectedItem?.id
    content(
      activeRows, activeRowsVersion, isActiveProjectionPending, isAwaitingFirstActiveProjection,
      activeTextRestorationID
    )
    .task(id: taskKey) {
      guard let projectedItem else {
        projectionWorker.cancel()
        projectionStaging.ready = ReadyProjection(key: taskKey, rows: [])
        controller.presentationClock.requestFrame()
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
        projectionStaging.ready = ReadyProjection(
          key: key,
          rows: output.rows,
          restorationID: TranscriptStreamingTextIdentity.restorationID(for: output.request.item)
        )
        controller.presentationClock.requestFrame()
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

    func canPublish(over current: Self) -> Bool {
      projectedID == current.projectedID
        && waitingDescription == current.waitingDescription
        && revision <= current.revision
    }
  }

  private struct ReadyProjection {
    let key: TaskKey
    let rows: [TranscriptPresentationRow]
    var restorationID: String? = nil
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
    activeTextRestorationID = readyProjection.restorationID
    activeRowsVersion &+= 1
    publishedProjectionKey = readyProjection.key
  }
}
