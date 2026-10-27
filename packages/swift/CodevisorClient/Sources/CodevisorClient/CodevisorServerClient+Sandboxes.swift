import Foundation

public struct ServerSandboxProvider: Decodable, Equatable, Sendable, Identifiable {
  public var id: String
  public var displayName: String
  public var configured: Bool

  public init(id: String, displayName: String, configured: Bool) {
    self.id = id
    self.displayName = displayName
    self.configured = configured
  }
}

public struct ServerSandboxSetupStep: Decodable, Equatable, Sendable {
  public var stage: String
  public var startedAt: String
  public var endedAt: String?

  public init(stage: String, startedAt: String, endedAt: String? = nil) {
    self.stage = stage
    self.startedAt = startedAt
    self.endedAt = endedAt
  }
}

public struct ServerSandbox: Decodable, Equatable, Sendable, Identifiable {
  public var id: String
  public var provider: String
  public var name: String
  public var state: String
  public var deviceId: String?
  public var remoteProjectId: String?
  public var workspaceId: String?
  public var plan: [String]?
  public var steps: [ServerSandboxSetupStep]?
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
    steps: [ServerSandboxSetupStep]? = nil,
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

private struct SandboxProvidersResponse: Decodable {
  var providers: [ServerSandboxProvider]
}

extension CodevisorServerClient {
  public func sandboxProviders() async throws -> [ServerSandboxProvider] {
    let response: SandboxProvidersResponse = try await get("/v1/sandbox-providers")
    return response.providers
  }

  public func sandboxes() async throws -> [ServerSandbox] {
    try await get("/v1/sandboxes")
  }

  public func destroySandbox(id: String) async throws {
    try await sendNoResponse("/v1/sandboxes/\(pathComponent(id))", method: "DELETE")
  }

  public func createSandbox(_ request: ServerSandboxRequest) async throws -> ServerSandbox {
    try await send("/v1/sandboxes", method: "POST", body: request)
  }

  public func claimSandboxWorkspace(id: String, workspaceId: UUID) async throws -> ServerSandbox {
    try await send(
      "/v1/sandboxes/\(pathComponent(id))/workspace",
      method: "POST",
      body: ["workspaceId": workspaceId.uuidString]
    )
  }
}
