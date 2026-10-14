import Foundation
import Observation
import Testing
import CodevisorTestSupport
@testable import CodevisorCore

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
  var isCloudRosterVerified = true
  var loopbackURLsByDeviceId: [String: URL] = [:]
  var loopbackRevisionsByDeviceId: [String: UInt64] = [:]
  var loopbackRecoverySucceeds = true
  private(set) var loopbackRecoveryRequests: [String] = []
  let requestTransport = FakeRelayRequestTransport()
  private(set) var configRequests: [String] = []
  private(set) var accountSyncPreparations: [String] = []

  func prepareAccountSync(on client: any CodevisorServerClienting, machineId: String) async -> Bool {
    accountSyncPreparations.append(machineId)
    return false
  }

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
  func loopbackRevision(for machine: CloudMachine) -> UInt64 {
    loopbackRevisionsByDeviceId[machine.deviceId, default: 0]
  }
  func recoverLoopbackBridge(for machine: CloudMachine) async -> Bool {
    loopbackRecoveryRequests.append(machine.deviceId)
    return loopbackRecoverySucceeds
  }

  func relayClient(for machine: CodevisorMachine) -> any CodevisorServerClienting {
    let deviceId = CodevisorMachine.cloudDeviceId(forMachineId: machine.id)
    let cloud = cloudMachines.first { $0.deviceId == deviceId }
    return CodevisorServerClient(
      config: cloud.flatMap(relayServerConfig) ?? .unreachable(machineId: machine.id))
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

@MainActor
func makeController(
  store: InMemoryStore = InMemoryStore(),
  localServer: (any LocalServerControlling)? = StubLocalServer(),
  provider: FakeCloudProvider = FakeCloudProvider(),
  clientFactory: MachineController.ClientFactory? = nil,
  reconnectNoticeScheduler: SessionConnectionRecoveryScheduler = .continuous
) -> (controller: MachineController, projectList: ProjectListModel, provider: FakeCloudProvider) {
  let projectList = ProjectListModel.fixture()
  let controller = MachineController(
    store: store,
    projectList: projectList,
    localServer: localServer,
    clientFactory: clientFactory,
    reconnectNoticeScheduler: reconnectNoticeScheduler
  )
  controller.cloudProvider = provider
  return (controller, projectList, provider)
}

@MainActor
func accountMachine(_ deviceId: String, name: String? = nil) -> CodevisorMachine {
  CodevisorMachine.cloud(from: makeCloudMachine(deviceId: deviceId, name: name ?? deviceId))
}

@MainActor
@discardableResult
func signIn(_ controller: MachineController, machines: [CodevisorMachine]) -> FakeCloudProvider {
  let provider = FakeCloudProvider()
  provider.cloudMachines = machines.compactMap { machine in
    CodevisorMachine.cloudDeviceId(forMachineId: machine.id).map {
      makeCloudMachine(deviceId: $0, name: machine.name)
    }
  }
  controller.cloudProvider = provider
  for machine in machines {
    controller.markReady(for: machine.id)
  }
  return provider
}
