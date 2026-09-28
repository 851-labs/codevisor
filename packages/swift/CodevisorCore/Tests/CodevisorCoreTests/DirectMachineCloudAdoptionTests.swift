import CodevisorCloud
import Foundation
import Testing
@testable import CodevisorCore

@MainActor
@Suite("Retired directly paired machines move onto the cloud account once")
struct DirectMachineCloudAdoptionTests {
  private let studio = PendingDirectMachine(
    id: "remote-studio-49361", name: "Studio", baseURL: URL(string: "http://studio.test:49361")!)

  @Test("A machine not yet on the account is registered under its name, reached with its old token")
  func registersUnregisteredMachine() async throws {
    let world = try World(pending: [studio], tokens: ["remote-studio-49361": "old-token"])
    world.server.respond("/v1/cloud", json: #"{"connected":false}"#)
    world.provider.adoptedDeviceId = "studio-device"

    await world.adoption.adoptPendingMachines(cloud: world.provider)

    #expect(world.server.requests == [.init(url: "http://studio.test:49361/v1/cloud", bearer: "old-token")])
    #expect(world.provider.adoptions == ["Studio"])
    #expect(world.settled == [.init(oldId: "remote-studio-49361", cloudId: "cloud:studio-device")])
    #expect(world.tokens.removed == ["remote-studio-49361"])
    #expect(!world.adoption.hasPendingMachines)
    #expect(world.store.loadData(forKey: DirectMachineCloudAdoption.storeKey) == nil)
  }

  @Test("A machine already on this account is only recognized, and an inline legacy token is used")
  func recognizesMachineAlreadyOnAccount() async throws {
    var legacy = studio
    legacy.legacyToken = "inline-token"
    let world = try World(pending: [legacy])
    world.provider.cloudMachines = [makeCloudMachine(deviceId: "studio-device", name: "Studio")]
    world.server.respond("/v1/cloud", json: #"{"connected":true,"deviceId":"studio-device"}"#)

    await world.adoption.adoptPendingMachines(cloud: world.provider)

    #expect(world.server.requests.map(\.bearer) == ["inline-token"])
    #expect(world.provider.adoptions.isEmpty)
    #expect(world.settled == [.init(oldId: "remote-studio-49361", cloudId: "cloud:studio-device")])
  }

  @Test(
    "A machine that can't be moved is dropped after one attempt",
    arguments: [
      "on another account",
      "token refused",
      "unreachable",
    ])
  func dropsMachineThatCannotMove(failure: String) async throws {
    let world = try World(pending: [studio], tokens: ["remote-studio-49361": "old-token"])
    switch failure {
    case "on another account":
      world.server.respond("/v1/cloud", json: #"{"connected":true,"deviceId":"someone-elses"}"#)
    case "token refused":
      world.server.respond("/v1/cloud", json: #"{"error":"unauthorized"}"#, status: 401)
    default:
      break  // No response scripted: fails like an unreachable host.
    }

    await world.adoption.adoptPendingMachines(cloud: world.provider)

    #expect(world.provider.adoptions.isEmpty)
    #expect(world.settled == [.init(oldId: "remote-studio-49361", cloudId: nil)])
    #expect(world.tokens.removed == ["remote-studio-49361"])
    #expect(!DirectMachineCloudAdoption(store: world.store).hasPendingMachines)
  }

  @Test("Nothing is attempted while signed out or before the account's machine list is verified")
  func waitsForVerifiedSignedInAccount() async throws {
    let world = try World(pending: [studio])
    world.server.respond("/v1/cloud", json: #"{"connected":false}"#)

    world.provider.isCloudSignedIn = false
    await world.adoption.adoptPendingMachines(cloud: world.provider)
    world.provider.isCloudSignedIn = true
    world.provider.isCloudRosterVerified = false
    await world.adoption.adoptPendingMachines(cloud: world.provider)

    #expect(world.server.requests.isEmpty)
    #expect(DirectMachineCloudAdoption(store: world.store).hasPendingMachines)
  }

  @Test("Overlapping passes register each machine once")
  func overlappingPassesRegisterOnce() async throws {
    let world = try World(pending: [studio])
    world.server.respond("/v1/cloud", json: #"{"connected":false}"#)

    async let first: Void = world.adoption.adoptPendingMachines(cloud: world.provider)
    async let second: Void = world.adoption.adoptPendingMachines(cloud: world.provider)
    _ = await (first, second)

    #expect(world.provider.adoptions == ["Studio"])
    #expect(world.settled.count == 1)
  }

  @Test("Queuing keeps machines already waiting unchanged")
  func enqueueIsIdempotent() throws {
    let store = InMemoryStore()
    var legacy = studio
    legacy.legacyToken = "inline-token"
    try DirectMachineCloudAdoption.enqueue([legacy], in: store)
    try DirectMachineCloudAdoption.enqueue([studio], in: store)
    let queued = try JSONDecoder().decode(
      [PendingDirectMachine].self,
      from: #require(store.loadData(forKey: DirectMachineCloudAdoption.storeKey)))
    #expect(queued == [legacy])
  }
}

@MainActor
private final class World {
  struct Settled: Equatable {
    var oldId: String
    var cloudId: String?
  }

  let store = InMemoryStore()
  let tokens: TokenKeychain
  let server = ScriptedServerTransport()
  let provider = AdoptingCloudProvider()
  let adoption: DirectMachineCloudAdoption
  private(set) var settled: [Settled] = []

  init(pending: [PendingDirectMachine], tokens: [String: String] = [:]) throws {
    self.tokens = TokenKeychain(tokens)
    try DirectMachineCloudAdoption.enqueue(pending, in: store)
    let server = server
    adoption = DirectMachineCloudAdoption(
      store: store,
      readToken: self.tokens.read,
      removeToken: self.tokens.remove,
      clientFactory: { config in
        CodevisorServerClient(
          config: CodevisorServerConfig(
            baseURL: config.baseURL,
            bearerToken: config.bearerToken,
            requestTransport: server,
            webSocketTransport: UnusedWebSocketTransport()
          ))
      }
    )
    adoption.onSettled = { [weak self] in self?.settled.append(Settled(oldId: $0, cloudId: $1)) }
  }
}

@MainActor
private final class AdoptingCloudProvider: CloudMachineProviding {
  var isCloudSignedIn = true
  var cloudMachines: [CloudMachine] = []
  var isCloudRosterVerified = true
  var adoptedDeviceId = "adopted-device"
  private(set) var adoptions: [String] = []

  func relayServerConfig(for machine: CloudMachine) -> CodevisorServerConfig? { nil }

  func adoptDirectMachine(using client: any CodevisorServerClienting, name: String) async throws -> String {
    adoptions.append(name)
    return adoptedDeviceId
  }
}

/// The retired machine tokens' Keychain items.
private final class TokenKeychain: @unchecked Sendable {
  private let lock = NSLock()
  private var tokens: [String: String]
  private var removedIds: [String] = []

  init(_ tokens: [String: String]) {
    self.tokens = tokens
  }

  var removed: [String] { lock.withLock { removedIds } }

  func read(_ id: String) throws -> String? {
    lock.withLock { tokens[id] }
  }

  func remove(_ id: String) throws {
    lock.withLock {
      removedIds.append(id)
      tokens[id] = nil
    }
  }
}

/// Answers a directly paired machine's requests by path; an unscripted path
/// fails like an unreachable host.
private final class ScriptedServerTransport: ServerRequestTransport, @unchecked Sendable {
  struct Request: Equatable {
    var url: String
    var bearer: String?
  }

  private let lock = NSLock()
  private var responses: [String: (status: Int, body: String)] = [:]
  private var recorded: [Request] = []

  var requests: [Request] { lock.withLock { recorded } }

  func respond(_ path: String, json: String, status: Int = 200) {
    lock.withLock { responses[path] = (status, json) }
  }

  func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    let url = try #require(request.url)
    let bearer = request.value(forHTTPHeaderField: "Authorization").map {
      $0.replacingOccurrences(of: "Bearer ", with: "")
    }
    let response = lock.withLock {
      recorded.append(Request(url: url.absoluteString, bearer: bearer))
      return responses[url.path]
    }
    guard let response else { throw URLError(.cannotConnectToHost) }
    let http = try #require(
      HTTPURLResponse(
        url: url, statusCode: response.status, httpVersion: "HTTP/1.1",
        headerFields: ["Content-Type": "application/json"]))
    return (Data(response.body.utf8), http)
  }
}
