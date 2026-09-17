import Foundation

/// Transient control messages travel only on the authenticated media peer.
/// A fresh host-issued lease prevents delayed input from a previous control period.
public enum ScreenSharingControlMessage: Codable, Sendable, Equatable {
  case request(id: UUID)
  case grant(request: UUID, lease: UUID)
  case denied(request: UUID, reason: String)
  case release(lease: UUID)
  case revoked(lease: UUID, reason: String)
  case heartbeat(lease: UUID)
  case input(lease: UUID, sequence: UInt64, event: ScreenSharingInputEvent)

  public static let maximumBytes = 4096
  public func encoded() throws -> Data {
    let data = try JSONEncoder().encode(Envelope(version: 1, message: self))
    guard data.count <= Self.maximumBytes else { throw ScreenSharingError.invalid("Control message is too large.") }
    return data
  }
  public static func decode(_ data: Data) throws -> Self {
    guard data.count <= maximumBytes else { throw ScreenSharingError.invalid("Control message is too large.") }
    let envelope = try JSONDecoder().decode(Envelope.self, from: data)
    guard envelope.version == 1 else { throw ScreenSharingError.invalid("Unsupported control protocol.") }
    if case .input(_, _, let event) = envelope.message, !event.isValid {
      throw ScreenSharingError.invalid("Invalid control input.")
    }
    return envelope.message
  }
  private struct Envelope: Codable { let version: Int; let message: ScreenSharingControlMessage }
}

public struct ScreenSharingPointer: Codable, Sendable, Equatable {
  public let x: Double
  public let y: Double
  public init(x: Double, y: Double) { self.x = x; self.y = y }
  public var isValid: Bool { x.isFinite && y.isFinite && (0...1).contains(x) && (0...1).contains(y) }
}

/// Physical Mac key codes use the host's keyboard layout. Text insertion is a
/// separate operation; it must never be interpreted as a physical shortcut.
public enum ScreenSharingInputEvent: Codable, Sendable, Equatable {
  case move(ScreenSharingPointer, modifiers: UInt8)
  case button(ScreenSharingPointer, button: UInt8, down: Bool, clicks: UInt8, modifiers: UInt8)
  case scroll(ScreenSharingPointer, x: Int32, y: Int32, modifiers: UInt8)
  case key(code: UInt16, down: Bool, repeatKey: Bool, modifiers: UInt8)
  case text(String)

  public var isValid: Bool {
    switch self {
    case .move(let point, let flags): point.isValid && flags < 64
    case .button(let point, let button, _, let clicks, let flags):
      point.isValid && button <= 2 && (1...3).contains(clicks) && flags < 64
    case .scroll(let point, let x, let y, let flags):
      point.isValid && (-4096...4096).contains(x) && (-4096...4096).contains(y) && flags < 64
    case .key(let code, _, _, let flags): code <= 126 && flags < 64
    case .text(let text): !text.isEmpty && text.utf16.count <= 1024
    }
  }
}

/// Coordinates are normalized in the captured display, with the origin at its
/// top left. This is independent of Retina scale and the display's global origin.
public enum ScreenSharingVideoGeometry {
  public static func pointer(
    x: Double, y: Double, surfaceWidth: Double, surfaceHeight: Double,
    videoWidth: Double, videoHeight: Double, clamp: Bool = false
  ) -> ScreenSharingPointer? {
    guard [x, y, surfaceWidth, surfaceHeight, videoWidth, videoHeight].allSatisfy(\.isFinite),
      surfaceWidth > 0, surfaceHeight > 0, videoWidth > 0, videoHeight > 0
    else { return nil }
    let scale = min(surfaceWidth / videoWidth, surfaceHeight / videoHeight)
    let width = videoWidth * scale; let height = videoHeight * scale
    let px = (x - (surfaceWidth - width) / 2) / width
    let py = (y - (surfaceHeight - height) / 2) / height
    let point = ScreenSharingPointer(x: clamp ? min(1, max(0, px)) : px, y: clamp ? min(1, max(0, py)) : py)
    return point.isValid ? point : nil
  }
}
