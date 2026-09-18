import ScreenSharing
import Foundation

/// A repeatable control check: the viewer asks for control, sends N clicks at one normalized point, then
/// releases. On a host whose source is the workload on a virtual display, each click bumps the workload's
/// Response counter, which the host publishes, so delivery is proven without touching anyone's desktop.
public struct RigControlCheckRequest: Codable, Equatable, Sendable {
  public let clicks: Int
  /// Space key presses after the clicks; the workload counts each non-repeat `keyDown`.
  public let keys: Int
  public let x: Double
  public let y: Double
  public init(clicks: Int, keys: Int = 0, x: Double = 0.5, y: Double = 0.5) {
    self.clicks = clicks
    self.keys = keys
    self.x = x
    self.y = y
  }
  public var expectedResponses: Int { clicks + keys }

  private enum CodingKeys: String, CodingKey { case clicks, keys, x, y }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    clicks = try container.decode(Int.self, forKey: .clicks)
    keys = try container.decodeIfPresent(Int.self, forKey: .keys) ?? 0
    x = try container.decodeIfPresent(Double.self, forKey: .x) ?? 0.5
    y = try container.decodeIfPresent(Double.self, forKey: .y) ?? 0.5
  }
}

public struct RigControlCheckResponse: Codable, Equatable, Sendable {
  public let granted: Bool
  public let deniedReason: String?
  public let clicksSent: Int
  public let keysSent: Int
  public let responsesBefore: Int?
  public let responsesAfter: Int?
  public let revokedReason: String?
  /// True when the host's Response counter advanced by exactly the clicks and keys sent.
  public var delivered: Bool {
    guard let responsesBefore, let responsesAfter else { return false }
    return responsesAfter - responsesBefore == clicksSent + keysSent
  }
  public init(
    granted: Bool, deniedReason: String?, clicksSent: Int, keysSent: Int = 0, responsesBefore: Int?,
    responsesAfter: Int?, revokedReason: String?
  ) {
    self.granted = granted
    self.deniedReason = deniedReason
    self.clicksSent = clicksSent
    self.keysSent = keysSent
    self.responsesBefore = responsesBefore
    self.responsesAfter = responsesAfter
    self.revokedReason = revokedReason
  }
}

public enum RigControlCheckPlan {
  /// macOS virtual key code for the space bar.
  public static let spaceKeyCode: UInt16 = 49

  /// The input events for `clicks` clicks at one point followed by `keys` space presses: one move, then
  /// button down/up pairs each with their own coordinates as the protocol requires, then key down/up
  /// pairs. Sequence numbers start at 1 and are contiguous.
  public typealias PlannedEvent = (sequence: UInt64, event: ScreenSharingInputEvent)

  public static func events(clicks: Int, keys: Int = 0, x: Double, y: Double) -> [PlannedEvent] {
    let pointer = ScreenSharingPointer(x: x, y: y)
    var events: [ScreenSharingInputEvent] = [.move(pointer, modifiers: 0)]
    for _ in 0..<max(0, clicks) {
      events.append(.button(pointer, button: 0, down: true, clicks: 1, modifiers: 0))
      events.append(.button(pointer, button: 0, down: false, clicks: 1, modifiers: 0))
    }
    for _ in 0..<max(0, keys) {
      events.append(.key(code: spaceKeyCode, down: true, repeatKey: false, modifiers: 0))
      events.append(.key(code: spaceKeyCode, down: false, repeatKey: false, modifiers: 0))
    }
    return events.enumerated().map { (UInt64($0.offset + 1), $0.element) }
  }
}
