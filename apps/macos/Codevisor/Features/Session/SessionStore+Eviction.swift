import Foundation
import Observation
import CodevisorCore
import ACPKit

extension SessionStore {
  func noteAccess(_ key: SessionKey) {
    accessOrder.removeAll { $0 == key }
    accessOrder.append(key)
    evictIdleControllers()
  }

  func isRunning(_ key: SessionKey) -> Bool {
    guard let controller = controllers[key] else { return false }
    return Self.isInProgress(controller) || controller.isConnecting
  }

  func evictIdleControllers() {
    let idle = accessOrder.filter { id in
      guard let controller = controllers[id] else { return false }
      return id != openSessionKey
        && !isRunning(id)
        && !controller.isWaitingOnBackgroundTasks
        && controller.goal?.status != .active
    }
    guard idle.count > Self.maxIdleControllers else { return }
    for id in idle.dropLast(Self.maxIdleControllers) {
      let controller = controllers.removeValue(forKey: id)
      controller?.onScrollStateChange = nil
      controller?.model?.shutdown()
      scrollStates[id] = nil
      transcriptSurfaces.remove(sessionID: id.sessionId)
    }
  }
}
