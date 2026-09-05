import Foundation
import Observation
import Testing
import CodevisorTestSupport
@testable import CodevisorCore

/// Shared cloud-machine fixtures for the MachineController suites.
/// A canned-response request transport standing in for the cloud relay:
/// records every request and serves JSON by path.
@Observable
final class FakeRelayRequestTransport: ServerRequestTransport, @unchecked Sendable {
  private let lock = NSLock()
  private var requestedPaths: [String] = []
  var responsesByPath: [String: String] = [:]
  var gatesByPath: [String: TestSignal] = [:]

  var paths: [String] {
    lock.withLock { requestedPaths }
  }

  func requestCount(for path: String) -> Int {
    lock.withLock { requestedPaths.count { $0 == path } }
  }

  func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    let path = request.url?.path ?? ""
    lock.withLock { requestedPaths.append(path) }
    if let gate = gatesByPath[path] { await gate.wait() }
    guard let body = responsesByPath[path] else {
      throw URLError(.fileDoesNotExist)
    }
    let response = HTTPURLResponse(
      url: request.url!,
      statusCode: 200,
      httpVersion: "HTTP/1.1",
      headerFields: ["Content-Type": "application/json"]
    )!
    return (Data(body.utf8), response)
  }
}

final class UnusedWebSocketTransport: ServerWebSocketTransport, @unchecked Sendable {
  func connect(_ request: URLRequest, maximumMessageSize: Int) -> any ServerWebSocketConnecting {
    UnusedWebSocketConnection()
  }
}

/// Never exercised: the fake relay config's request transport answers
/// everything, so no socket is ever opened.
final class UnusedWebSocketConnection: ServerWebSocketConnecting, @unchecked Sendable {
  var closeCode: URLSessionWebSocketTask.CloseCode { .invalid }

  func send(_ message: ServerWebSocketMessage) async throws {}
  func receive() async throws -> ServerWebSocketMessage {
    throw URLError(.cancelled)
  }
  func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {}
}

@MainActor
final class FakeCloudProvider: CloudMachineProviding {
  var isCloudSignedIn = true
  var cloudMachines: [CloudMachine] = []
  /// Simulates a listening loopback bridge for a machine, like
  /// CloudAccountController publishes once its bridge is up.
  var loopbackURLsByDeviceId: [String: URL] = [:]
  let requestTransport = FakeRelayRequestTransport()
  private(set) var configRequests: [String] = []

  func relayServerConfig(for machine: CloudMachine) -> CodevisorServerConfig? {
    configRequests.append(machine.deviceId)
    return CodevisorServerConfig(
      baseURL: loopbackBaseURL(for: machine) ?? CodevisorMachine.cloudPlaceholderBaseURL,
      bearerToken: nil,
      requestTransport: requestTransport,
      webSocketTransport: UnusedWebSocketTransport()
    )
  }

  func loopbackBaseURL(for machine: CloudMachine) -> URL? {
    loopbackURLsByDeviceId[machine.deviceId]
  }
}

@MainActor
func makeCloudMachine(
  deviceId: String = "dev-1",
  name: String = "Cloud Mac",
  online: Bool = true
) -> CloudMachine {
  CloudMachine(
    deviceId: deviceId,
    name: name,
    os: "macOS",
    publicKey: "pk-\(deviceId)",
    online: online,
    lastSeenAt: "2026-01-01T00:00:00.000Z"
  )
}

/// Defaults to a working local server (the mac shape). Tests that model
/// a client-only platform (iOS) pass `localServer: nil` explicitly —
/// those platforms list no "Local" machine and auto-adopt real ones.
@MainActor
func makeController(
  store: InMemoryStore = InMemoryStore(),
  localServer: (any LocalServerControlling)? = StubLocalServer(),
  clientFactory: MachineController.ClientFactory? = nil
) -> (controller: MachineController, projectList: ProjectListModel, provider: FakeCloudProvider) {
  let projectList = ProjectListModel(
    projectRepository: DefaultProjectRepository(store: InMemoryStore()),
    sessionRepository: DefaultSessionRepository(store: InMemoryStore())
  )
  let controller = MachineController(
    store: store,
    projectList: projectList,
    localServer: localServer,
    clientFactory: clientFactory
  )
  let provider = FakeCloudProvider()
  controller.cloudProvider = provider
  return (controller, projectList, provider)
}
