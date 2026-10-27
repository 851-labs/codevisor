import Foundation

public struct ServerEphemeralProvider: Decodable, Equatable, Sendable, Identifiable {
  public var id: String
  public var displayName: String
  public var configured: Bool

  public init(id: String, displayName: String, configured: Bool) {
    self.id = id
    self.displayName = displayName
    self.configured = configured
  }
}

public struct ServerEphemeralSetupStep: Decodable, Equatable, Sendable {
  public var stage: String
  public var startedAt: String
  public var endedAt: String?

  public init(stage: String, startedAt: String, endedAt: String? = nil) {
    self.stage = stage
    self.startedAt = startedAt
    self.endedAt = endedAt
  }
}

public struct ServerEphemeralMachine: Decodable, Equatable, Sendable, Identifiable {
  public var id: String
  public var provider: String
  public var name: String
  public var state: String
  public var deviceId: String?
  public var remoteProjectId: String?
  public var workspaceId: String?
  public var plan: [String]?
  public var steps: [ServerEphemeralSetupStep]?
  public var error: String?

  public init(
    id: String,
    provider: String,
    name: String,
    state: String,
    deviceId: String? = nil,
    remoteProjectId: String? = nil,
    workspaceId: String? = nil,
    plan: [String]? = nil,
    steps: [ServerEphemeralSetupStep]? = nil,
    error: String? = nil
  ) {
    self.id = id
    self.provider = provider
    self.name = name
    self.state = state
    self.deviceId = deviceId
    self.remoteProjectId = remoteProjectId
    self.workspaceId = workspaceId
    self.plan = plan
    self.steps = steps
    self.error = error
  }
}

private struct EphemeralProvidersResponse: Decodable {
  var providers: [ServerEphemeralProvider]
}

extension CodevisorServerClient {
  public func ephemeralProviders() async throws -> [ServerEphemeralProvider] {
    let response: EphemeralProvidersResponse = try await get("/v1/ephemeral-providers")
    return response.providers
  }

  public func ephemeralMachines() async throws -> [ServerEphemeralMachine] {
    try await get("/v1/ephemeral-machines")
  }

  public func destroyEphemeralMachine(id: String) async throws {
    try await sendNoResponse("/v1/ephemeral-machines/\(pathComponent(id))", method: "DELETE")
  }

  public func createEphemeralMachine(_ request: ServerEphemeralMachineRequest) async throws -> ServerEphemeralMachine {
    try await send("/v1/ephemeral-machines", method: "POST", body: request)
  }

  public func claimEphemeralWorkspace(id: String, workspaceId: UUID) async throws -> ServerEphemeralMachine {
    try await send(
      "/v1/ephemeral-machines/\(pathComponent(id))/workspace",
      method: "POST",
      body: ["workspaceId": workspaceId.uuidString]
    )
  }
}
