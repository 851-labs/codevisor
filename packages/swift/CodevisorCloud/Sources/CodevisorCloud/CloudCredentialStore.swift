import CodevisorClient
import Foundation
import Security

public protocol CloudCredentialStore: Sendable {
  func token() throws -> String?
  func saveToken(_ token: String) throws
  func removeToken() throws
  func serverURL() throws -> URL?
  func saveServerURL(_ url: URL?) throws
  func appDeviceId() throws -> String?
  func saveAppDeviceId(_ id: String) throws
  func appSecretKey() throws -> Data?
  func saveAppSecretKey(_ key: Data) throws
  func pinnedMachineKeys() throws -> [String: String]
  func savePinnedMachineKeys(_ pins: [String: String]) throws
  func loadRoster() -> CachedRoster?
  func saveRoster(_ roster: CachedRoster)
  func clearRoster()
}

public struct CachedRoster: Codable, Equatable, Sendable {
  public var serverURL: String
  public var userEmail: String?
  public var machines: [CloudMachine]

  public init(serverURL: String, userEmail: String?, machines: [CloudMachine]) {
    self.serverURL = serverURL
    self.userEmail = userEmail
    self.machines = machines
  }
}

public struct CloudAppDeviceIdentity: Sendable {
  public let deviceId: String
  public let secretKey: Data
  public let publicKey: String

  public init(deviceId: String, secretKey: Data, publicKey: String) {
    self.deviceId = deviceId
    self.secretKey = secretKey
    self.publicKey = publicKey
  }
}

private let appDeviceIdentityLock = NSLock()

extension CloudCredentialStore {
  public func ensureAppDeviceIdentity() throws -> CloudAppDeviceIdentity {
    try appDeviceIdentityLock.withLock { try loadOrMintAppDeviceIdentity() }
  }

  private func loadOrMintAppDeviceIdentity() throws -> CloudAppDeviceIdentity {
    let deviceId: String
    if let stored = try appDeviceId() {
      deviceId = stored
    } else {
      deviceId = UUID().uuidString.lowercased()
      try saveAppDeviceId(deviceId)
    }
    if let secret = try appSecretKey(),
      let publicKey = try? CloudChannelCrypto.publicKey(forSecretKey: secret)
    {
      return CloudAppDeviceIdentity(deviceId: deviceId, secretKey: secret, publicKey: publicKey)
    }
    let pair = CloudChannelCrypto.generateKeyPair()
    try saveAppSecretKey(pair.secretKey)
    return CloudAppDeviceIdentity(
      deviceId: deviceId,
      secretKey: pair.secretKey,
      publicKey: pair.publicKey
    )
  }
}

public struct CloudCredentialError: Error, LocalizedError, Sendable {
  public let operation: String
  public let status: OSStatus

  public var errorDescription: String? {
    let detail = SecCopyErrorMessageString(status, nil) as String? ?? "status \(status)"
    return "Cloud credential \(operation) failed: \(detail)"
  }
}

public final class KeychainCloudCredentialStore: CloudCredentialStore, @unchecked Sendable {
  public static let shared = KeychainCloudCredentialStore()

  private static let tokenAccount = "session-token"
  private static let serverURLAccount = "server-url"
  private static let appDeviceIdAccount = "app-device-id"
  private static let appSecretKeyAccount = "app-device-secret-key"
  private static let machineKeyPinsAccount = "machine-key-pins"

  private let values: KeychainValueStore
  private let rosterDefaults: UserDefaults
  private let rosterKey: String

  public convenience init() {
    self.init(service: KeychainCredentialServices.cloud)
  }

  public init(service: String, rosterDefaults: UserDefaults = .standard) {
    values = KeychainValueStore(service: service)
    self.rosterDefaults = rosterDefaults
    rosterKey = Self.rosterKey(service: service)
  }

  public init(service: String, operations: KeychainOperations, rosterDefaults: UserDefaults = .standard) {
    values = KeychainValueStore(service: service, operations: operations)
    self.rosterDefaults = rosterDefaults
    rosterKey = Self.rosterKey(service: service)
  }

  private static func rosterKey(service: String) -> String {
    "cloud-roster-v1.\(service)"
  }

  public func token() throws -> String? {
    try read(account: Self.tokenAccount)
  }

  public func saveToken(_ token: String) throws {
    try write(token, account: Self.tokenAccount)
  }

  public func removeToken() throws {
    try remove(account: Self.tokenAccount)
  }

  public func serverURL() throws -> URL? {
    try read(account: Self.serverURLAccount).flatMap(URL.init(string:))
  }

  public func saveServerURL(_ url: URL?) throws {
    if let url {
      try write(url.absoluteString, account: Self.serverURLAccount)
    } else {
      try remove(account: Self.serverURLAccount)
    }
  }

  public func appDeviceId() throws -> String? {
    try read(account: Self.appDeviceIdAccount)
  }

  public func saveAppDeviceId(_ id: String) throws {
    try write(id, account: Self.appDeviceIdAccount)
  }

  public func appSecretKey() throws -> Data? {
    try read(account: Self.appSecretKeyAccount)
      .flatMap { Data(base64Encoded: $0) }
  }

  public func saveAppSecretKey(_ key: Data) throws {
    try write(key.base64EncodedString(), account: Self.appSecretKeyAccount)
  }

  public func pinnedMachineKeys() throws -> [String: String] {
    guard let raw = try read(account: Self.machineKeyPinsAccount),
      let data = raw.data(using: .utf8),
      let pins = try? JSONDecoder().decode([String: String].self, from: data)
    else {
      return [:]
    }
    return pins
  }

  public func savePinnedMachineKeys(_ pins: [String: String]) throws {
    let data = try JSONEncoder().encode(pins)
    try write(String(decoding: data, as: UTF8.self), account: Self.machineKeyPinsAccount)
  }

  public func loadRoster() -> CachedRoster? {
    guard let data = rosterDefaults.data(forKey: rosterKey) else { return nil }
    return try? JSONDecoder().decode(CachedRoster.self, from: data)
  }

  public func saveRoster(_ roster: CachedRoster) {
    guard let data = try? JSONEncoder().encode(roster) else { return }
    rosterDefaults.set(data, forKey: rosterKey)
  }

  public func clearRoster() {
    rosterDefaults.removeObject(forKey: rosterKey)
  }

  private func read(account: String) throws -> String? {
    try mapFailure { try values.value(forAccount: account) }
  }

  private func write(_ value: String, account: String) throws {
    try mapFailure { try values.saveValue(value, forAccount: account) }
  }

  private func remove(account: String) throws {
    try mapFailure { try values.removeValue(forAccount: account) }
  }

  private func mapFailure<T>(_ operation: () throws -> T) throws -> T {
    do {
      return try operation()
    } catch let failure as KeychainStorageFailure {
      throw CloudCredentialError(operation: failure.operation, status: failure.status)
    }
  }
}

public final class InMemoryCloudCredentialStore: CloudCredentialStore, @unchecked Sendable {
  private let lock = NSLock()
  private var storedToken: String?
  private var storedServerURL: URL?
  private var storedAppDeviceId: String?
  private var storedAppSecretKey: Data?
  private var storedMachineKeyPins: [String: String] = [:]
  private var storedRoster: CachedRoster?

  public init(token: String? = nil, serverURL: URL? = nil, roster: CachedRoster? = nil) {
    storedToken = token
    storedServerURL = serverURL
    storedRoster = roster
  }

  public func token() throws -> String? {
    lock.withLock { storedToken }
  }

  public func saveToken(_ token: String) throws {
    lock.withLock { storedToken = token }
  }

  public func removeToken() throws {
    lock.withLock { storedToken = nil }
  }

  public func serverURL() throws -> URL? {
    lock.withLock { storedServerURL }
  }

  public func saveServerURL(_ url: URL?) throws {
    lock.withLock { storedServerURL = url }
  }

  public func appDeviceId() throws -> String? {
    lock.withLock { storedAppDeviceId }
  }

  public func saveAppDeviceId(_ id: String) throws {
    lock.withLock { storedAppDeviceId = id }
  }

  public func appSecretKey() throws -> Data? {
    lock.withLock { storedAppSecretKey }
  }

  public func saveAppSecretKey(_ key: Data) throws {
    lock.withLock { storedAppSecretKey = key }
  }

  public func pinnedMachineKeys() throws -> [String: String] {
    lock.withLock { storedMachineKeyPins }
  }

  public func savePinnedMachineKeys(_ pins: [String: String]) throws {
    lock.withLock { storedMachineKeyPins = pins }
  }

  public func loadRoster() -> CachedRoster? {
    lock.withLock { storedRoster }
  }

  public func saveRoster(_ roster: CachedRoster) {
    lock.withLock { storedRoster = roster }
  }

  public func clearRoster() {
    lock.withLock { storedRoster = nil }
  }
}
