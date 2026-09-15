import CodevisorScreenSharing
import Foundation

/// A repeatable control check: the viewer asks for control, sends N clicks at one normalized point, then
/// releases. On a host whose source is the workload on a virtual display, each click bumps the workload's
/// Response counter, which the host publishes, so delivery is proven without touching anyone's desktop.
public struct RigControlCheckRequest: Codable, Equatable, Sendable {
  public let clicks: Int
  public let x: Double
  public let y: Double
  public init(clicks: Int, x: Double = 0.5, y: Double = 0.5) {
    self.clicks = clicks
    self.x = x
    self.y = y
  }
}

public struct RigControlCheckResponse: Codable, Equatable, Sendable {
  public let granted: Bool
  public let deniedReason: String?
  public let clicksSent: Int
  public let responsesBefore: Int?
  public let responsesAfter: Int?
  public let revokedReason: String?
  /// True when the host's Response counter advanced by exactly the clicks sent.
  public var delivered: Bool {
    guard let responsesBefore, let responsesAfter else { return false }
    return responsesAfter - responsesBefore == clicksSent
  }
  public init(
    granted: Bool, deniedReason: String?, clicksSent: Int, responsesBefore: Int?, responsesAfter: Int?,
    revokedReason: String?
  ) {
    self.granted = granted
    self.deniedReason = deniedReason
    self.clicksSent = clicksSent
    self.responsesBefore = responsesBefore
    self.responsesAfter = responsesAfter
    self.revokedReason = revokedReason
  }
}

public enum RigControlCheckPlan {
  /// The input events for `clicks` clicks at one point: one move, then down/up pairs, each with its own
  /// coordinates as the protocol requires. Sequence numbers start at 1 and are contiguous.
  public static func events(clicks: Int, x: Double, y: Double) -> [(sequence: UInt64, event: ScreenSharingInputEvent)] {
    let pointer = ScreenSharingPointer(x: x, y: y)
    var events: [ScreenSharingInputEvent] = [.move(pointer, modifiers: 0)]
    for _ in 0..<max(0, clicks) {
      events.append(.button(pointer, button: 0, down: true, clicks: 1, modifiers: 0))
      events.append(.button(pointer, button: 0, down: false, clicks: 1, modifiers: 0))
    }
    return events.enumerated().map { (UInt64($0.offset + 1), $0.element) }
  }
}
