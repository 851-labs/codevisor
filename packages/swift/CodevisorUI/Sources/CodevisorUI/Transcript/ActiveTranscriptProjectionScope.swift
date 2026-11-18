import CodevisorCore
import SwiftUI
import TranscriptKit

public struct ActiveTranscriptProjectionScope<Content: View>: View {
  private let controller: SessionController
  private let projectedRows: [TranscriptPresentationRow]
  private let sharedProjection: ActiveTranscriptProjection?
  private let content: ([TranscriptPresentationRow], UInt64, Bool, Bool, String?) -> Content
  @State private var activeRows: [TranscriptPresentationRow] = []
  @State private var activeRowsVersion: UInt64 = 0
  @State private var activeTextRestorationID: String?
  @State private var publishedProjectionKey: TaskKey?
  @State private var projectionStaging = ProjectionStaging()
  @State private var projectionWorker = TranscriptActiveProjectionWorker()
  @State private var ownProjection = ActiveTranscriptProjectionFallback()
  @State private var frameObserver = UUID()

  public init(
    controller: SessionController,
    projectedRows: [TranscriptPresentationRow],
    projection: ActiveTranscriptProjection? = nil,
    @ViewBuilder content: @escaping ([TranscriptPresentationRow], UInt64, Bool, Bool, String?) -> Content
  ) {
    self.controller = controller
    self.projectedRows = projectedRows
    sharedProjection = projection
    self.content = content
  }

  private var projection: ActiveTranscriptProjection { sharedProjection ?? ownProjection.projection }

  public var body: some View {
    #if os(macOS)
      framedBody
    #else
      legacyBody
    #endif
  }

  private var framedBody: some View {
    let projection = projection
    let isAwaitingFirstProjection =
      projectedItem != nil && projection.publishedKey?.projectedID != projectedItem?.id
    return content(
      projection.rows, projection.rowsVersion, isAwaitingFirstProjection, isAwaitingFirstProjection,
      projection.textRestorationID
    )
    .background {
      ActiveTranscriptProjectionSubmitter(
        controller: controller,
        projectedItem: projectedItem,
        worker: projection.worker,
        staging: projection.staging
      )
    }
    .onAppear { projection.observeFrames(of: controller.presentationClock, for: frameObserver) }
    .onChange(of: ActiveTranscriptProjectionBinding(projection: projection, controller: controller)) { old, new in
      old.projection.stopObservingFrames(for: frameObserver)
      new.projection.observeFrames(of: new.controller.presentationClock, for: frameObserver)
    }
    .onDisappear { projection.stopObservingFrames(for: frameObserver) }
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
