import Foundation

/// Apple simulators on a Mac with Xcode (`simulator-v1`, `/v1/simulators`).

public struct ServerSimulatorRuntime: Codable, Sendable, Hashable, Identifiable {
  public let identifier: String
  /// "iOS 27.0"
  public let name: String
  public let platform: String
  public let version: String
  public let deviceTypeIdentifiers: [String]
  public var id: String { identifier }

  public init(identifier: String, name: String, platform: String, version: String, deviceTypeIdentifiers: [String]) {
    self.identifier = identifier; self.name = name; self.platform = platform
    self.version = version; self.deviceTypeIdentifiers = deviceTypeIdentifiers
  }
}

public struct ServerSimulatorDeviceType: Codable, Sendable, Hashable, Identifiable {
  public let identifier: String
  public let name: String
  /// "iPhone", "iPad", "Apple TV", "Apple Watch", "Apple Vision"
  public let productFamily: String
  public var id: String { identifier }

  public init(identifier: String, name: String, productFamily: String) {
    self.identifier = identifier; self.name = name; self.productFamily = productFamily
  }
}

public struct ServerSimulatorDevice: Codable, Sendable, Hashable, Identifiable {
  public struct Runtime: Codable, Sendable, Hashable {
    public let identifier: String
    public let name: String
    public let platform: String
    public let version: String

    public init(identifier: String, name: String, platform: String, version: String) {
      self.identifier = identifier; self.name = name; self.platform = platform; self.version = version
    }
  }

  public let udid: String
  public let name: String
  /// simctl's state: "Booted", "Shutdown", "Booting", "Shutting Down", "Creating"
  public let state: String
  public let runtime: Runtime
  public let deviceType: ServerSimulatorDeviceType
  public let lastBootedAt: String?
  public var id: String { udid }

  public var isBooted: Bool { state == "Booted" }
  public var isShutdown: Bool { state == "Shutdown" }

  public init(
    udid: String, name: String, state: String, runtime: Runtime,
    deviceType: ServerSimulatorDeviceType, lastBootedAt: String? = nil
  ) {
    self.udid = udid; self.name = name; self.state = state; self.runtime = runtime
    self.deviceType = deviceType; self.lastBootedAt = lastBootedAt
  }
}

public struct ServerSimulatorList: Codable, Sendable, Equatable {
  public let devices: [ServerSimulatorDevice]
  public let deviceTypes: [ServerSimulatorDeviceType]
  public let runtimes: [ServerSimulatorRuntime]

  public init(
    devices: [ServerSimulatorDevice], deviceTypes: [ServerSimulatorDeviceType], runtimes: [ServerSimulatorRuntime]
  ) {
    self.devices = devices; self.deviceTypes = deviceTypes; self.runtimes = runtimes
  }
}

/// One screen of a device type; a foldable has a cover and an inner one.
public struct ServerSimulatorDisplay: Codable, Sendable, Equatable {
  public let name: String
  /// Pixels in the display's native orientation.
  public let width: Double
  public let height: Double
  public let scale: Double
  /// Upper-left, upper-right, lower-left, lower-right, in points.
  public let cornerRadii: [Double]
  public let chromeIdentifier: String?
  /// A PDF the screen is clipped to, base64.
  public let mask: String?
  public let hasDigitizer: Bool

  public init(
    name: String, width: Double, height: Double, scale: Double, cornerRadii: [Double],
    chromeIdentifier: String? = nil, mask: String? = nil, hasDigitizer: Bool
  ) {
    self.name = name; self.width = width; self.height = height; self.scale = scale
    self.cornerRadii = cornerRadii; self.chromeIdentifier = chromeIdentifier
    self.mask = mask; self.hasDigitizer = hasDigitizer
  }
}

public struct ServerSimulatorDeviceTypeDetail: Codable, Sendable, Equatable {
  public let identifier: String
  public let name: String
  public let productFamily: String
  public let features: [String]
  public let chromeIdentifier: String?
  public let displays: [ServerSimulatorDisplay]

  public init(
    identifier: String, name: String, productFamily: String, features: [String],
    chromeIdentifier: String?, displays: [ServerSimulatorDisplay]
  ) {
    self.identifier = identifier; self.name = name; self.productFamily = productFamily
    self.features = features; self.chromeIdentifier = chromeIdentifier; self.displays = displays
  }
}

/// A DeviceKit chrome bundle: chrome.json (raw) and its PDFs, base64.
public struct ServerSimulatorChrome: Sendable, Equatable {
  public let identifier: String
  public let definition: Data
  public let images: [String: String]

  public init(identifier: String, definition: Data, images: [String: String]) {
    self.identifier = identifier; self.definition = definition; self.images = images
  }
}

/// One of the Mac's audio devices a simulator's sound can play through or record from.
public struct ServerSimulatorAudioDevice: Codable, Sendable, Equatable, Hashable, Identifiable {
  public var uid: String
  public var name: String
  public var id: String { uid }

  public init(uid: String, name: String) {
    self.uid = uid
    self.name = name
  }
}

/// A running simulator's settings, as Device Hub offers them. A setting the runtime (or the Mac's
/// Xcode) doesn't support is nil. Audio routes are `"system"` or a device's `uid`.
public struct ServerSimulatorSettings: Codable, Sendable, Equatable {
  public static let systemAudioRoute = "system"

  public var appearance: String?
  public var contentSize: String?
  public var increaseContrast: Bool?
  public var reduceMotion: Bool?
  public var showBorders: Bool?
  public var reduceTransparency: Bool?
  public var voiceOver: Bool?
  public var location: String
  public var volume: Double?
  public var audioOutput: String?
  public var audioInput: String?
  public var audioOutputs: [ServerSimulatorAudioDevice]?
  public var audioInputs: [ServerSimulatorAudioDevice]?

  public init(
    appearance: String? = nil, contentSize: String? = nil, increaseContrast: Bool? = nil,
    reduceMotion: Bool? = nil, showBorders: Bool? = nil, reduceTransparency: Bool? = nil, voiceOver: Bool? = nil,
    location: String = "none", volume: Double? = nil, audioOutput: String? = nil, audioInput: String? = nil,
    audioOutputs: [ServerSimulatorAudioDevice]? = nil, audioInputs: [ServerSimulatorAudioDevice]? = nil
  ) {
    self.appearance = appearance
    self.contentSize = contentSize
    self.increaseContrast = increaseContrast
    self.reduceMotion = reduceMotion
    self.showBorders = showBorders
    self.reduceTransparency = reduceTransparency
    self.voiceOver = voiceOver
    self.location = location
    self.volume = volume
    self.audioOutput = audioOutput
    self.audioInput = audioInput
    self.audioOutputs = audioOutputs
    self.audioInputs = audioInputs
  }

  /// The settings with a change applied, before the device confirms it.
  public func applying(_ change: ServerSimulatorSettingsChange) -> Self {
    var settings = self
    if let value = change.appearance { settings.appearance = value }
    if let value = change.contentSize { settings.contentSize = value }
    if let value = change.increaseContrast { settings.increaseContrast = value }
    if let value = change.reduceMotion { settings.reduceMotion = value }
    if let value = change.showBorders { settings.showBorders = value }
    if let value = change.reduceTransparency { settings.reduceTransparency = value }
    if let value = change.voiceOver { settings.voiceOver = value }
    if let value = change.location { settings.location = value }
    if let value = change.volume { settings.volume = value }
    if let value = change.audioOutput { settings.audioOutput = value }
    if let value = change.audioInput { settings.audioInput = value }
    return settings
  }
}

public struct ServerSimulatorSettingsChange: Codable, Sendable, Equatable {
  public var udid: String
  public var appearance: String?
  public var contentSize: String?
  public var increaseContrast: Bool?
  public var reduceMotion: Bool?
  public var showBorders: Bool?
  public var reduceTransparency: Bool?
  public var voiceOver: Bool?
  public var location: String?
  public var volume: Double?
  public var audioOutput: String?
  public var audioInput: String?

  public init(udid: String) {
    self.udid = udid
  }
}

public enum ServerSimulatorAction: String, Codable, Sendable {
  case boot, shutdown, restart, delete
}

public protocol SimulatorClienting: Sendable {
  func simulators() async throws -> ServerSimulatorList
  func simulatorDeviceType(identifier: String) async throws -> ServerSimulatorDeviceTypeDetail
  func simulatorChrome(identifier: String) async throws -> ServerSimulatorChrome
  func performSimulatorAction(_ action: ServerSimulatorAction, udid: String) async throws
  func createSimulator(name: String, deviceTypeIdentifier: String, runtimeIdentifier: String) async throws -> String
  func renameSimulator(udid: String, name: String) async throws
  func simulatorSettings(udid: String) async throws -> ServerSimulatorSettings
  func changeSimulatorSettings(_ change: ServerSimulatorSettingsChange) async throws -> ServerSimulatorSettings
  func simulatorScreenshot(udid: String) async throws -> Data
}

private struct SimulatorActionBody: Encodable {
  let udid: String
  let action: ServerSimulatorAction
}

private struct SimulatorCreateBody: Encodable {
  let name: String
  let deviceTypeIdentifier: String
  let runtimeIdentifier: String
}

private struct SimulatorCreated: Decodable { let udid: String }
private struct SimulatorRenameBody: Encodable { let udid: String; let name: String }
private struct SimulatorEmpty: Decodable {}

extension CodevisorServerClient: SimulatorClienting {
  public func simulators() async throws -> ServerSimulatorList {
    try await get("/v1/simulators")
  }

  public func simulatorDeviceType(identifier: String) async throws -> ServerSimulatorDeviceTypeDetail {
    try await get("/v1/simulators/device-type?\(Self.query("identifier", identifier))")
  }

  public func simulatorChrome(identifier: String) async throws -> ServerSimulatorChrome {
    let data = try await perform(
      "/v1/simulators/chrome?\(Self.query("identifier", identifier))", method: "GET",
      body: Optional<SimulatorEmptyBody>.none)
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      let definition = object["definition"],
      let images = object["images"] as? [String: String]
    else { throw CodevisorServerClientError.invalidResponse }
    return ServerSimulatorChrome(
      identifier: identifier,
      definition: try JSONSerialization.data(withJSONObject: definition),
      images: images)
  }

  public func performSimulatorAction(_ action: ServerSimulatorAction, udid: String) async throws {
    let _: SimulatorEmpty = try await send(
      "/v1/simulators/devices/action", method: "POST", body: SimulatorActionBody(udid: udid, action: action),
      timeout: 180)
  }

  public func createSimulator(
    name: String, deviceTypeIdentifier: String, runtimeIdentifier: String
  ) async throws
    -> String
  {
    let created: SimulatorCreated = try await send(
      "/v1/simulators/devices", method: "POST",
      body: SimulatorCreateBody(
        name: name, deviceTypeIdentifier: deviceTypeIdentifier, runtimeIdentifier: runtimeIdentifier),
      timeout: 90)
    return created.udid
  }

  public func renameSimulator(udid: String, name: String) async throws {
    let _: SimulatorEmpty = try await send(
      "/v1/simulators/devices/rename", method: "POST", body: SimulatorRenameBody(udid: udid, name: name))
  }

  public func simulatorSettings(udid: String) async throws -> ServerSimulatorSettings {
    try await get("/v1/simulators/settings?\(Self.query("udid", udid))")
  }

  public func changeSimulatorSettings(_ change: ServerSimulatorSettingsChange) async throws -> ServerSimulatorSettings {
    try await send("/v1/simulators/settings", method: "POST", body: change, timeout: 60)
  }

  public func simulatorScreenshot(udid: String) async throws -> Data {
    try await performRaw(
      "/v1/simulators/screenshot?\(Self.query("udid", udid))", method: "GET", body: nil, contentType: nil)
  }

  private static func query(_ name: String, _ value: String) -> String {
    var components = URLComponents()
    components.queryItems = [URLQueryItem(name: name, value: value)]
    return components.percentEncodedQuery ?? ""
  }
}

private struct SimulatorEmptyBody: Encodable {}

/// Test doubles and older clients: a machine without simulators.
public extension SimulatorClienting {
  private var unsupported: CodevisorServerClientError {
    .httpStatus(501, "Simulators need Xcode and the Codevisor app on this Mac.")
  }
  func simulators() async throws -> ServerSimulatorList { throw unsupported }
  func simulatorDeviceType(identifier: String) async throws -> ServerSimulatorDeviceTypeDetail { throw unsupported }
  func simulatorChrome(identifier: String) async throws -> ServerSimulatorChrome { throw unsupported }
  func performSimulatorAction(_ action: ServerSimulatorAction, udid: String) async throws { throw unsupported }
  func createSimulator(
    name: String, deviceTypeIdentifier: String, runtimeIdentifier: String
  ) async throws
    -> String
  { throw unsupported }
  func renameSimulator(udid: String, name: String) async throws { throw unsupported }
  func simulatorSettings(udid: String) async throws -> ServerSimulatorSettings { throw unsupported }
  func changeSimulatorSettings(_ change: ServerSimulatorSettingsChange) async throws -> ServerSimulatorSettings {
    throw unsupported
  }
  func simulatorScreenshot(udid: String) async throws -> Data { throw unsupported }
}
