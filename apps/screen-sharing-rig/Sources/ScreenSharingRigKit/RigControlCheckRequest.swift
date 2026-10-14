import ScreenSharing
import Foundation

public struct RigControlCheckRequest: Codable, Equatable, Sendable {
  public let clicks: Int
  public let keys: Int
  public let x: Double
  public let y: Double
  public init(clicks: Int, keys: Int = 0, x: Double = 0.5, y: Double = 0.5) {
    self.clicks = clicks
    self.keys = keys
    self.x = x
    self.y = y
  }

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
  public static let spaceKeyCode: UInt16 = 49

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
