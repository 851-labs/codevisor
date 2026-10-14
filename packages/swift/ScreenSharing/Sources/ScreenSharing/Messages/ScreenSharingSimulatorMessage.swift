import Foundation

public enum ScreenSharingSimulatorMessage: Codable, Sendable, Equatable {
  case touch(phase: ScreenSharingSimulatorTouchPhase, touches: [ScreenSharingSimulatorTouch])
  case button(name: String, down: Bool)
  case key(usage: Int, down: Bool)
  case crown(delta: Double)
  case rotate(ScreenSharingSimulatorOrientation)
  case posture(String)
  case state(ScreenSharingSimulatorState)

  public static let maximumBytes = 4096

  public func encoded() throws -> Data {
    let data = try JSONEncoder().encode(Envelope(version: 1, message: self))
    guard data.count <= Self.maximumBytes else { throw ScreenSharingError.invalid("Simulator message is too large.") }
    return data
  }

  public static func decode(_ data: Data) throws -> Self {
    guard data.count <= maximumBytes else { throw ScreenSharingError.invalid("Simulator message is too large.") }
    let envelope = try JSONDecoder().decode(Envelope.self, from: data)
    guard envelope.version == 1 else { throw ScreenSharingError.invalid("Unsupported simulator protocol.") }
    return envelope.message
  }

  private struct Envelope: Codable {
    let version: Int
    let message: ScreenSharingSimulatorMessage
  }
}

public enum ScreenSharingSimulatorTouchPhase: String, Codable, Sendable {
  case began, moved, ended, cancelled
}

public struct ScreenSharingSimulatorTouch: Codable, Sendable, Equatable {
  public var id: Int
  public var x: Double
  public var y: Double
  public var edge: ScreenSharingSimulatorEdge?

  public init(id: Int, x: Double, y: Double, edge: ScreenSharingSimulatorEdge? = nil) {
    self.id = id; self.x = x; self.y = y; self.edge = edge
  }
}

public enum ScreenSharingSimulatorEdge: String, Codable, Sendable {
  case top, bottom, left, right
}

public enum ScreenSharingSimulatorOrientation: String, Codable, Sendable, CaseIterable {
  case portrait
  case landscapeLeft
  case portraitUpsideDown
  case landscapeRight

  public var degrees: Double {
    switch self {
    case .portrait: 0
    case .landscapeRight: 90
    case .portraitUpsideDown: 180
    case .landscapeLeft: 270
    }
  }

  public var quarterTurns: Int { Int(degrees / 90) }

  public var isLandscape: Bool { self == .landscapeLeft || self == .landscapeRight }

  public func turned(clockwise: Bool) -> Self {
    let order: [Self] = [.portrait, .landscapeRight, .portraitUpsideDown, .landscapeLeft]
    let index = order.firstIndex(of: self) ?? 0
    return order[(index + (clockwise ? 1 : order.count - 1)) % order.count]
  }
}

public struct ScreenSharingSimulatorState: Codable, Sendable, Equatable {
  public var orientation: ScreenSharingSimulatorOrientation
  public var posture: String?
  public var postures: [String]
  public var display: String?
  public var canRotate: Bool
  public var screenTurns: Int?
  public var mountings: [String: Int]?

  public init(
    orientation: ScreenSharingSimulatorOrientation, posture: String? = nil, postures: [String] = [],
    display: String? = nil, canRotate: Bool = true, screenTurns: Int? = nil, mountings: [String: Int]? = nil
  ) {
    self.orientation = orientation; self.posture = posture; self.postures = postures
    self.display = display; self.canRotate = canRotate; self.screenTurns = screenTurns
    self.mountings = mountings
  }
}
