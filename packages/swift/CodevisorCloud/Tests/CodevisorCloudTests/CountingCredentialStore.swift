import Observation
import CodevisorTestSupport
import Foundation
import Testing
import ACPKit
import CodevisorClient
import CodevisorProtocol
@testable import CodevisorCloud

// Shared helpers for the CloudHubConnection suites (extracted so the test
// files stay under the structural lint limits).

@Observable

final class Recorder: @unchecked Sendable {
  private let lock = NSLock()
  private var receivedMessages: [Data] = []
  private var closeReasons: [CloudChannelCloseReason?] = []

  var messages: [Data] {
    lock.withLock { receivedMessages }
  }

  var closes: [CloudChannelCloseReason?] {
    lock.withLock { closeReasons }
  }

  func record(_ data: Data) {
    lock.withLock { receivedMessages.append(data) }
  }

  func recordClose(_ reason: CloudChannelCloseReason?) {
    lock.withLock { closeReasons.append(reason) }
  }
}

@Observable

final class CountingCredentialStore: CloudCredentialStore, @unchecked Sendable {
  private let base: InMemoryCloudCredentialStore
  private let lock = NSLock()
  private var tokenReadCount = 0
  private var deviceIdReadCount = 0
  private var secretKeyReadCount = 0

  init(base: InMemoryCloudCredentialStore) {
    self.base = base
  }

  var readCounts: (token: Int, deviceId: Int, secretKey: Int) {
    lock.withLock { (tokenReadCount, deviceIdReadCount, secretKeyReadCount) }
  }

  func token() throws -> String? {
    lock.withLock { tokenReadCount += 1 }
    return try base.token()
  }

  func saveToken(_ token: String) throws { try base.saveToken(token) }
  func removeToken() throws { try base.removeToken() }
  func serverURL() throws -> URL? { try base.serverURL() }
  func saveServerURL(_ url: URL?) throws { try base.saveServerURL(url) }

  func appDeviceId() throws -> String? {
    lock.withLock { deviceIdReadCount += 1 }
    return try base.appDeviceId()
  }

  func saveAppDeviceId(_ id: String) throws { try base.saveAppDeviceId(id) }

  func appSecretKey() throws -> Data? {
    lock.withLock { secretKeyReadCount += 1 }
    return try base.appSecretKey()
  }

  func saveAppSecretKey(_ key: Data) throws { try base.saveAppSecretKey(key) }
  func pinnedMachineKeys() throws -> [String: String] { try base.pinnedMachineKeys() }
  func savePinnedMachineKeys(_ pins: [String: String]) throws {
    try base.savePinnedMachineKeys(pins)
  }
}

@Observable

final class SocketQueue: @unchecked Sendable {
  private let lock = NSLock()
  private var sockets: [any ServerWebSocketConnecting]

  init(_ sockets: [any ServerWebSocketConnecting]) {
    self.sockets = sockets
  }

  func next() -> any ServerWebSocketConnecting {
    lock.withLock {
      if sockets.count > 1 { return sockets.removeFirst() }
      return sockets[0]
    }
  }
}

func makeHub(
  _ scripted: ScriptedCloudHub,
  heartbeatInterval: Duration = .seconds(30),
  heartbeatTimeout: Duration = .seconds(10),
  onMachineWait: @escaping @Sendable () -> Void = {}
) -> (hub: CloudHubConnection, store: InMemoryCloudCredentialStore) {
  let store = InMemoryCloudCredentialStore(token: "session-token")
  let hub = CloudHubConnection(
    serverURL: URL(string: "https://cloud.example.com")!,
    credentialStore: store,
    deviceName: "Test App",
    deviceOS: "macOS",
    webSocketTransport: FakeWebSocketTransport { _ in scripted.socket },
    readyTimeout: .seconds(2),
    heartbeatInterval: heartbeatInterval,
    heartbeatTimeout: heartbeatTimeout,
    sleep: TestClock().sleep,
    reconnectDelay: { _ in .zero },
    onMachineWait: onMachineWait
  )
  return (hub, store)
}
