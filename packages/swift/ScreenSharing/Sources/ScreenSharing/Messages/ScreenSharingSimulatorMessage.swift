import Foundation

/// An Apple simulator's input and device state, on the `codevisor.simulator.v1` channel of a
/// `simulator:<udid>` stream. The video is the simulator's framebuffer in its native (portrait)
/// orientation; the viewer turns it as the device is turned, and sends touches back in that
/// framebuffer's coordinates. A peer without the channel never opens it.
public enum ScreenSharingSimulatorMessage: Codable, Sendable, Equatable {
  /// Viewer → host: fingers on the screen, normalized 0…1 from the framebuffer's top-left.
  case touch(phase: ScreenSharingSimulatorTouchPhase, touches: [ScreenSharingSimulatorTouch])
  /// Viewer → host: a hardware button by its chrome name ("power", "volume-up", "home", …).
  case button(name: String, down: Bool)
  /// Viewer → host: a keyboard key by its HID usage (page 7).
  case key(usage: Int, down: Bool)
  /// Viewer → host: turn the Digital Crown (positive is up).
  case crown(delta: Double)
  /// Viewer → host: turn the device.
  case rotate(ScreenSharingSimulatorOrientation)
  /// Viewer → host: fold or unfold a foldable to one of the state's postures.
  case posture(String)
  /// Host → viewer: what the device is doing now. Sent on open and on every change.
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
  /// Stable for one finger from `began` to `ended`.
  public var id: Int
  public var x: Double
  public var y: Double
  /// The screen edge a system gesture started from (Home indicator, Control Center), or nil.
  public var edge: ScreenSharingSimulatorEdge?

  public init(id: Int, x: Double, y: Double, edge: ScreenSharingSimulatorEdge? = nil) {
    self.id = id; self.x = x; self.y = y; self.edge = edge
  }
}

/// Edges in framebuffer coordinates.
public enum ScreenSharingSimulatorEdge: String, Codable, Sendable {
  case top, bottom, left, right
}

/// The way the device is held, named for where its native top points.
public enum ScreenSharingSimulatorOrientation: String, Codable, Sendable, CaseIterable {
  case portrait
  /// Turned so its top faces left (the Home indicator on the right).
  case landscapeLeft
  case portraitUpsideDown
  case landscapeRight

  /// Clockwise turn of the device from portrait, in degrees.
  public var degrees: Double {
    switch self {
    case .portrait: 0
    case .landscapeRight: 90
    case .portraitUpsideDown: 180
    case .landscapeLeft: 270
    }
  }

  /// Clockwise quarter turns from portrait.
  public var quarterTurns: Int { Int(degrees / 90) }

  public var isLandscape: Bool { self == .landscapeLeft || self == .landscapeRight }

  /// One quarter turn clockwise (`clockwise`) or counterclockwise.
  public func turned(clockwise: Bool) -> Self {
    let order: [Self] = [.portrait, .landscapeRight, .portraitUpsideDown, .landscapeLeft]
    let index = order.firstIndex(of: self) ?? 0
    return order[(index + (clockwise ? 1 : order.count - 1)) % order.count]
  }
}

public struct ScreenSharingSimulatorState: Codable, Sendable, Equatable {
  public var orientation: ScreenSharingSimulatorOrientation
  /// The foldable's current posture, nil for a device that doesn't fold.
  public var posture: String?
  /// Postures the device offers, in order ("closed", "book", "open").
  public var postures: [String]
  /// The streamed screen's name in the device type's display list ("primary", "primary-1").
  public var display: String?
  /// Whether this host can turn the device; a viewer hides Rotate when it can't.
  public var canRotate: Bool
  /// Clockwise quarter turns the streamed screen is mounted at in the device (the iPhone Duo's
  /// inner screen is sideways). The video comes as the screen is made; a viewer turns it, frame
  /// and all, this far plus however the device is held. Nil from hosts before it, meaning upright.
  public var screenTurns: Int?
  /// How every screen of the device is mounted, by name, in clockwise quarter turns: a foldable
  /// is drawn at one size whichever screen shows, as it is in the hand.
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
