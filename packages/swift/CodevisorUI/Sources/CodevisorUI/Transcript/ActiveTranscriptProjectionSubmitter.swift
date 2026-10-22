import CodevisorCore
import SwiftUI
import TranscriptKit

struct ActiveTranscriptProjectionSubmitter: View {
  let controller: SessionController
  let projectedItem: ConversationItem?
  let worker: TranscriptActiveProjectionWorker
  let staging: ActiveTranscriptProjectionStaging

  var body: some View {
    let key = ActiveTranscriptProjectionKey(controller: controller, projectedItem: projectedItem)
    Color.clear
      .task(id: key) { submit(key) }
  }

  private func submit(_ key: ActiveTranscriptProjectionKey) {
    staging.latestKey = key
    guard let projectedItem else { return stageEmptyProjection(key) }

    let item = TranscriptActiveItemResolver.resolve(
      projected: projectedItem,
      live: controller.activeItem,
      settled: controller.settledConversation
    )
    let request = TranscriptActiveProjectionWorker.Request(
      revision: key.revision,
      projectedID: projectedItem.id,
      item: item,
      waitingOnBackgroundTask: key.waitingDescription
    )
    worker.submit(request) { output in
      staging.ready = ActiveTranscriptReadyProjection(
        key: key,
        rows: output.rows,
        restorationID: TranscriptStreamingTextIdentity.restorationID(for: output.request.item)
      )
      controller.presentationClock.requestFrame()
    }
  }

  private func stageEmptyProjection(_ key: ActiveTranscriptProjectionKey) {
    worker.cancel()
    staging.ready = ActiveTranscriptReadyProjection(key: key, rows: [])
    controller.presentationClock.requestFrame()
  }
}
