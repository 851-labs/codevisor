import Foundation
import Observation
import CodevisorCore
import ACPKit

extension SessionStore {
  func isInProgress(_ session: ChatSession) -> Bool {
    guard let controller = controllers[SessionKey(session)] else {
      return session.sidebarState == .inProgress
    }
    return Self.isInProgress(controller)
  }

  static func isActivelyWorking(_ controller: SessionController) -> Bool {
    controller.isSending
      || controller.setupPhases.contains(where: \.isRunning)
  }

  static func isInProgress(_ controller: SessionController) -> Bool {
    controller.pendingUserMessage != nil
      || isActivelyWorking(controller)
      || controller.isWaitingOnBackgroundTasks
  }

  func isWaitingOnUser(_ session: ChatSession) -> Bool {
    guard let controller = controllers[SessionKey(session)] else {
      return session.actionRequired
    }
    return session.actionRequired
      || controller.pendingQuestion != nil
      || controller.pendingPlanApproval
  }
}
