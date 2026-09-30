import Foundation
import Security
import Testing
import CodevisorCloud

import CodevisorProtocol

@testable import CodevisorClient

@Suite("Keychain credential stores")
struct KeychainCredentialStoreTests {
  @Test("Released builds retain the existing credential service names")
  func releasedServiceNamesRemainStable() {
    let machine = KeychainCredentialServices.scopedService(
      productionService: KeychainCredentialServices.productionMachine,
      isDevelopment: false,
      developmentInstanceID: "ignored",
      bundleIdentifier: "com.example.ignored"
    )
    let cloud = KeychainCredentialServices.scopedService(
      productionService: KeychainCredentialServices.productionCloud,
      isDevelopment: false,
      developmentInstanceID: "ignored",
      bundleIdentifier: "com.example.ignored"
    )

    #expect(machine == "com.851labs.Codevisor.machine-token")
    #expect(cloud == "com.851labs.Codevisor.cloud-session")
  }

  @Test("Development credentials are isolated by app instance and purpose")
  func developmentServicesAreIsolated() {
    let machineA = scopedDevelopmentService(
      KeychainCredentialServices.productionMachine,
      instanceID: "worktree-a"
    )
    let machineB = scopedDevelopmentService(
      KeychainCredentialServices.productionMachine,
      instanceID: "worktree-b"
    )
    let cloudA = scopedDevelopmentService(
      KeychainCredentialServices.productionCloud,
      instanceID: "worktree-a"
    )

    #expect(machineA == "com.851labs.Codevisor.machine-token.development.worktree-a")
    #expect(machineA != machineB)
    #expect(machineA != cloudA)
  }

  @Test("A bare development launch falls back to its bundle identifier")
  func developmentServiceFallsBackToBundleIdentifier() {
    let service = KeychainCredentialServices.scopedService(
      productionService: KeychainCredentialServices.productionCloud,
      isDevelopment: true,
      developmentInstanceID: "  ",
      bundleIdentifier: "com.851labs.Codevisor.Development.abc123"
    )

    #expect(
      service
        == "com.851labs.Codevisor.cloud-session.development.com.851labs.Codevisor.Development.abc123"
    )
  }

  @Test("Cloud credentials use the platform-default Keychain")
  func cloudCredentialsUsePlatformKeychain() throws {
    let keychain = FakeKeychain()
    let cloud = KeychainCloudCredentialStore(
      service: "cloud.dev-a",
      operations: keychain.operations
    )

    try cloud.saveToken("cloud-token")
    try cloud.saveServerURL(URL(string: "https://cloud.example")!)

    #expect(try cloud.token() == "cloud-token")
    #expect(try cloud.serverURL() == URL(string: "https://cloud.example"))
    #expect(keychain.value(service: "cloud.dev-a", account: "session-token") == "cloud-token")
    #expect(keychain.records.allSatisfy { !$0.usesDataProtectionKeychain })

    try cloud.removeToken()
    #expect(try cloud.token() == nil)
  }

  @Test("A save that loses an insert race to another writer still lands")
  func saveSurvivesConcurrentInsert() throws {
    let keychain = FakeKeychain()
    // Another writer inserts the item between this save's update (not found)
    // and its add — the first-launch race that surfaced as -25299.
    keychain.beforeNextAdd = { keychain.insert("theirs", service: "cloud.dev-a", account: "app-device-id") }
    let cloud = KeychainCloudCredentialStore(service: "cloud.dev-a", operations: keychain.operations)

    try cloud.saveAppDeviceId("ours")

    #expect(try cloud.appDeviceId() == "ours")
  }

  @Test("Concurrent first launches agree on one app device identity")
  func concurrentIdentityMintingConverges() throws {
    let keychain = FakeKeychain()
    let cloud = KeychainCloudCredentialStore(service: "cloud.dev-a", operations: keychain.operations)
    let results = LockedArray<Result<CloudAppDeviceIdentity, any Error>>()

    DispatchQueue.concurrentPerform(iterations: 8) { _ in
      results.append(Result { try cloud.ensureAppDeviceIdentity() })
    }

    let identities = try results.values.map { try $0.get() }
    #expect(identities.count == 8)
    #expect(Set(identities.map(\.deviceId)).count == 1)
    #expect(Set(identities.map(\.secretKey)).count == 1)
    #expect(try cloud.appDeviceId() == identities.first?.deviceId)
  }

  private func scopedDevelopmentService(
    _ productionService: String,
    instanceID: String
  ) -> String {
    KeychainCredentialServices.scopedService(
      productionService: productionService,
      isDevelopment: true,
      developmentInstanceID: instanceID,
      bundleIdentifier: "com.example.fallback"
    )
  }
}

private final class FakeKeychain: @unchecked Sendable {
  struct QueryRecord: Sendable {
    let service: String
    let account: String
    let usesDataProtectionKeychain: Bool
  }

  private struct Item: Hashable {
    let service: String
    let account: String
  }

  private let lock = NSLock()
  private var items: [Item: Data] = [:]
  private var recordedQueries: [QueryRecord] = []
  /// Runs once, just before the next add — a competing writer's insert.
  var beforeNextAdd: (() -> Void)?

  func insert(_ value: String, service: String, account: String) {
    lock.withLock { items[Item(service: service, account: account)] = Data(value.utf8) }
  }

  var operations: KeychainOperations {
    KeychainOperations(
      copyMatching: { [self] query in copy(query) },
      update: { [self] query, attributes in update(query, attributes) },
      add: { [self] attributes in add(attributes) },
      delete: { [self] query in delete(query) }
    )
  }

  var records: [QueryRecord] {
    lock.withLock { recordedQueries }
  }

  func value(service: String, account: String) -> String? {
    lock.withLock {
      items[Item(service: service, account: account)]
        .map { String(decoding: $0, as: UTF8.self) }
    }
  }

  private func copy(_ query: [String: Any]) -> (status: OSStatus, result: Any?) {
    lock.withLock {
      recordedQueries.append(record(query))
      guard let value = items[item(query)] else {
        return (errSecItemNotFound, nil)
      }
      return (errSecSuccess, value)
    }
  }

  private func update(_ query: [String: Any], _ attributes: [String: Any]) -> OSStatus {
    lock.withLock {
      recordedQueries.append(record(query))
      let key = item(query)
      guard items[key] != nil else { return errSecItemNotFound }
      guard let data = attributes[kSecValueData as String] as? Data else { return errSecParam }
      items[key] = data
      return errSecSuccess
    }
  }

  private func add(_ attributes: [String: Any]) -> OSStatus {
    let competingWriter = lock.withLock { () -> (() -> Void)? in
      defer { beforeNextAdd = nil }
      return beforeNextAdd
    }
    competingWriter?()
    return lock.withLock {
      recordedQueries.append(record(attributes))
      let key = item(attributes)
      guard items[key] == nil else { return errSecDuplicateItem }
      guard let data = attributes[kSecValueData as String] as? Data else { return errSecParam }
      items[key] = data
      return errSecSuccess
    }
  }

  private func delete(_ query: [String: Any]) -> OSStatus {
    lock.withLock {
      recordedQueries.append(record(query))
      return items.removeValue(forKey: item(query)) == nil ? errSecItemNotFound : errSecSuccess
    }
  }

  private func item(_ query: [String: Any]) -> Item {
    Item(
      service: query[kSecAttrService as String] as? String ?? "",
      account: query[kSecAttrAccount as String] as? String ?? ""
    )
  }

  private func record(_ query: [String: Any]) -> QueryRecord {
    QueryRecord(
      service: query[kSecAttrService as String] as? String ?? "",
      account: query[kSecAttrAccount as String] as? String ?? "",
      usesDataProtectionKeychain:
        query[kSecUseDataProtectionKeychain as String] as? Bool == true
    )
  }
}

private final class LockedArray<Element>: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: [Element] = []

  func append(_ element: Element) { lock.withLock { storage.append(element) } }
  var values: [Element] { lock.withLock { storage } }
}
