import CodevisorCore
import Foundation
import TranscriptKit

struct ActiveTranscriptProjectionKey: Hashable {
  let revision: UInt64
  let projectedID: UUID?
  let waitingDescription: String?

  @MainActor
  init(controller: SessionController, projectedItem: ConversationItem?) {
    revision = controller.activeItemRevision
    projectedID = projectedItem?.id
    waitingDescription = controller.waitingBackgroundTaskDescription
  }

  func canPublish(over current: Self) -> Bool {
    projectedID == current.projectedID
      && waitingDescription == current.waitingDescription
      && revision <= current.revision
  }
}

struct ActiveTranscriptReadyProjection {
  let key: ActiveTranscriptProjectionKey
  let rows: [TranscriptPresentationRow]
  var restorationID: String? = nil
}

@MainActor
final class ActiveTranscriptProjectionStaging {
  var ready: ActiveTranscriptReadyProjection?
  var latestKey: ActiveTranscriptProjectionKey?

  func takePublishable() -> ActiveTranscriptReadyProjection? {
    guard let ready, let latestKey, ready.key.canPublish(over: latestKey) else { return nil }
    self.ready = nil
    return ready
  }
}
