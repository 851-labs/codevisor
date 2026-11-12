import CodevisorCore
import Foundation

public struct SidebarChatActivity: Equatable, Sendable {
  public enum Request: Equatable, Sendable {
    case input
    case approval
  }

  public var request: Request?
  public var isSettingUp: Bool
  public var isWorking: Bool
  public var workingSince: Date?
  public var failure: SessionTurnFailure?

  public init(
    request: Request? = nil, isSettingUp: Bool = false, isWorking: Bool = false, workingSince: Date? = nil,
    failure: SessionTurnFailure? = nil
  ) {
    self.request = request
    self.isSettingUp = isSettingUp
    self.isWorking = isWorking
    self.workingSince = workingSince
    self.failure = failure
  }

  public init(session: ChatSession, isWorking: Bool, isSettingUp: Bool = false) {
    self.init(
      request: Self.request(of: session), isSettingUp: isSettingUp, isWorking: isWorking,
      workingSince: session.sidebarState == .inProgress ? session.sidebarStateChangedAt : nil,
      failure: session.lastTurnFailure)
  }

  var isBusy: Bool { isWorking || isSettingUp }

  private static func request(of session: ChatSession) -> Request? {
    if session.pendingPlanApproval { return .approval }
    guard session.actionRequired else { return nil }
    switch session.actionRequiredKind {
    case "approval", "planApproval": return .approval
    default: return .input
    }
  }
}
