import ScreenSharing
import Foundation

/// One resident rig process's configuration, read once from `rig.json`.
/// Values are validated here so a bad file fails at start, not mid-session.
public struct RigConfiguration: Sendable {
  public enum Role: String, Sendable { case host, viewer }

  public enum CaptureSource: Equatable, Sendable, CustomStringConvertible {
    /// Generated motion; needs no permission and no display.
    case synthetic
    /// The probe's own workload window, captured through current-process
    /// shareable content; needs no Screen Recording grant.
    case workload(width: Int, height: Int, framesPerSecond: Int)
    /// A physical display; requires Screen Recording on the host.
    case display(UInt32)
    /// A virtual display created through the private CGVirtualDisplay API with
    /// the workload window on it; requires Screen Recording on the host. Rig only.
    case virtual(width: Int, height: Int, framesPerSecond: Int)
    /// The same virtual display left bare: its own desktop, for moving real applications onto
    /// it. Requires Screen Recording. Rig only.
    case virtualDesktop(width: Int, height: Int, framesPerSecond: Int)
    /// Every on-screen window of one application, by bundle identifier; requires Screen Recording.
    case app(String)
    /// One window by CGWindowID, independent of what covers it; requires Screen Recording.
    case window(UInt32)

    public static func parse(_ text: String) throws -> CaptureSource {
      let trimmed = text.trimmingCharacters(in: .whitespaces)
      if trimmed == "synthetic" { return .synthetic }
      if trimmed.hasPrefix("app:") {
        let bundle = String(trimmed.dropFirst("app:".count))
        guard !bundle.isEmpty, bundle.range(of: "^[A-Za-z0-9.-]+$", options: .regularExpression) != nil else {
          throw ScreenSharingError.invalid("capture app needs a bundle identifier, e.g. app:com.apple.dt.Xcode")
        }
        return .app(bundle)
      }
      if trimmed.hasPrefix("window:") {
        guard let id = UInt32(trimmed.dropFirst("window:".count)), id > 0 else {
          throw ScreenSharingError.invalid("capture window needs a positive window ID, e.g. window:1234")
        }
        return .window(id)
      }
      if trimmed.hasPrefix("display:") {
        guard let id = UInt32(trimmed.dropFirst("display:".count)), id > 0 else {
          throw ScreenSharingError.invalid("capture display needs a positive display ID, e.g. display:1")
        }
        return .display(id)
      }
      if trimmed.hasPrefix("workload:") || trimmed.hasPrefix("virtual:") || trimmed.hasPrefix("virtual-desktop:") {
        let kind =
          trimmed.hasPrefix("virtual-desktop:")
          ? "virtual-desktop" : trimmed.hasPrefix("virtual:") ? "virtual" : "workload"
        let spec = trimmed.dropFirst(kind.count + 1)
        let parts = spec.split(separator: "@", omittingEmptySubsequences: false)
        let size = parts.first.map { $0.split(separator: "x", omittingEmptySubsequences: false) } ?? []
        guard parts.count == 2, size.count == 2, let width = Int(size[0]), let height = Int(size[1]),
          let fps = Int(parts[1]), (320...3840).contains(width), (240...2160).contains(height),
          width.isMultiple(of: 2), height.isMultiple(of: 2), (1...120).contains(fps)
        else {
          throw ScreenSharingError.invalid("capture \(kind) must look like \(kind):1920x1080@60")
        }
        switch kind {
        case "virtual-desktop": return .virtualDesktop(width: width, height: height, framesPerSecond: fps)
        case "virtual": return .virtual(width: width, height: height, framesPerSecond: fps)
        default: return .workload(width: width, height: height, framesPerSecond: fps)
        }
      }
      throw ScreenSharingError.invalid(
        "capture must be synthetic, workload:WxH@fps, virtual:WxH@fps, app:BUNDLE, window:ID or display:ID (got \(text))"
      )
    }

    public var description: String {
      switch self {
      case .synthetic: return "synthetic"
      case .workload(let width, let height, let fps): return "workload:\(width)x\(height)@\(fps)"
      case .display(let id): return "display:\(id)"
      case .virtual(let width, let height, let fps): return "virtual:\(width)x\(height)@\(fps)"
      case .virtualDesktop(let width, let height, let fps): return "virtual-desktop:\(width)x\(height)@\(fps)"
      case .app(let bundle): return "app:\(bundle)"
      case .window(let id): return "window:\(id)"
      }
    }
  }

  public static let defaultPort: UInt16 = 48731
  public static let defaultControlPort: UInt16 = 48732
  public static let minimumTokenLength = 16

  public let role: Role
  /// Host address (`host` or `host:port`) the viewer signals to.
  public let peer: String?
  /// LAN listener port on the host.
  public let port: UInt16
  /// Loopback control port on the viewer.
  public let controlPort: UInt16
  public let token: String
  public let video: ScreenSharingVideoConfiguration
  public let codec: ScreenSharingVideoCodec
  public let capture: CaptureSource
  public let hud: Bool
  public let telemetryDirectory: String?
  public let tuning: RigTuning

  public init(
    role: Role, peer: String?, port: UInt16 = RigConfiguration.defaultPort,
    controlPort: UInt16 = RigConfiguration.defaultControlPort, token: String,
    video: ScreenSharingVideoConfiguration, codec: ScreenSharingVideoCodec = .h264,
    capture: CaptureSource = .synthetic, hud: Bool = true, telemetryDirectory: String? = nil,
    tuning: RigTuning = .default
  ) throws {
    guard token.count >= Self.minimumTokenLength, token.rangeOfCharacter(from: .whitespacesAndNewlines) == nil
    else {
      throw ScreenSharingError.invalid(
        "token must be at least \(Self.minimumTokenLength) characters without whitespace")
    }
    if role == .viewer {
      guard let peer, !peer.trimmingCharacters(in: .whitespaces).isEmpty else {
        throw ScreenSharingError.invalid("a viewer needs peer, the host address")
      }
    }
    self.role = role
    self.peer = peer?.trimmingCharacters(in: .whitespaces)
    self.port = port
    self.controlPort = controlPort
    self.token = token
    self.video = video
    self.codec = codec
    self.capture = capture
    self.hud = hud
    self.telemetryDirectory = telemetryDirectory
    self.tuning = tuning
  }

  /// Parse `rig.json`. Unknown keys are rejected so typos cannot silently
  /// select defaults.
  public static func parse(_ data: Data) throws -> RigConfiguration {
    let object: Any
    do { object = try JSONSerialization.jsonObject(with: data) } catch {
      throw ScreenSharingError.invalid("rig.json is not valid JSON: \(error.localizedDescription)")
    }
    guard let dictionary = object as? [String: Any] else {
      throw ScreenSharingError.invalid("rig.json must be a JSON object")
    }
    let known: Set<String> = [
      "role", "peer", "port", "controlPort", "token", "width", "height", "fps", "bitrate", "codec", "capture", "hud",
      "telemetryDirectory", "tuning",
    ]
    let unknown = Set(dictionary.keys).subtracting(known).sorted()
    guard unknown.isEmpty else { throw ScreenSharingError.invalid("rig.json has unknown keys: \(unknown)") }
    func string(_ key: String) throws -> String? {
      guard let value = dictionary[key] else { return nil }
      guard let text = value as? String else { throw ScreenSharingError.invalid("\(key) must be a string") }
      return text
    }
    func integer(_ key: String, fallback: Int) throws -> Int {
      guard let value = dictionary[key] else { return fallback }
      guard let number = value as? NSNumber, !(value is Bool), number.doubleValue == number.doubleValue.rounded() else {
        throw ScreenSharingError.invalid("\(key) must be an integer")
      }
      return number.intValue
    }
    func port(_ key: String, fallback: UInt16) throws -> UInt16 {
      let value = try integer(key, fallback: Int(fallback))
      guard (1...65535).contains(value) else { throw ScreenSharingError.invalid("\(key) must be 1...65535") }
      return UInt16(value)
    }
    guard let roleText = try string("role"), let role = Role(rawValue: roleText) else {
      throw ScreenSharingError.invalid("role must be host or viewer")
    }
    guard let token = try string("token") else { throw ScreenSharingError.invalid("token is required") }
    let codecText = try string("codec") ?? "h264"
    guard let codec = ScreenSharingVideoCodec(rawValue: codecText) else {
      throw ScreenSharingError.invalid("codec must be one of \(ScreenSharingVideoCodec.allCases.map(\.rawValue))")
    }
    let video = try ScreenSharingVideoConfiguration(
      width: try integer("width", fallback: 1920), height: try integer("height", fallback: 1080),
      framesPerSecond: try integer("fps", fallback: 60), bitrate: try integer("bitrate", fallback: 12_000_000))
    let captureText = try string("capture")
    if role == .viewer, captureText != nil {
      throw ScreenSharingError.invalid("capture applies to the host role")
    }
    let capture = try captureText.map(CaptureSource.parse) ?? .synthetic
    let hud: Bool
    if let value = dictionary["hud"] {
      guard let flag = value as? Bool else { throw ScreenSharingError.invalid("hud must be true or false") }
      hud = flag
    } else {
      hud = true
    }
    var tuning = RigTuning.default
    if let value = dictionary["tuning"] {
      guard let object = value as? [String: Any] else { throw ScreenSharingError.invalid("tuning must be an object") }
      tuning = try RigTuning.parse(object)
    }
    return try RigConfiguration(
      role: role, peer: try string("peer"), port: try port("port", fallback: defaultPort),
      controlPort: try port("controlPort", fallback: defaultControlPort), token: token, video: video, codec: codec,
      capture: capture, hud: hud, telemetryDirectory: try string("telemetryDirectory"), tuning: tuning)
  }

  /// `http://host:port` for the viewer's signaling requests.
  public var hostBaseURL: URL? {
    guard let peer else { return nil }
    let target = peer.contains(":") && !peer.hasPrefix("[") ? peer : "\(peer):\(port)"
    return URL(string: "http://\(target)")
  }
}
