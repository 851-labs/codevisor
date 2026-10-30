import Foundation

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
  public var vendor: String
  public var name: String
  public var state: String
  public var profileId: String?
  public var profileName: String?
  public var accountId: String?
  public var deviceId: String?
  public var remoteProjectId: String?
  public var workspaceId: String?
  public var plan: [String]?
  public var steps: [ServerSandboxSetupStep]?
  public var power: String?
  public var error: String?

  private enum CodingKeys: String, CodingKey {
    case id, name, state, profileId, profileName, accountId, deviceId, remoteProjectId, workspaceId, plan, steps
    case power, error
    case vendor = "provider"
  }

  public init(
    id: String,
    vendor: String,
    name: String,
    state: String,
    profileId: String? = nil,
    profileName: String? = nil,
    accountId: String? = nil,
    deviceId: String? = nil,
    remoteProjectId: String? = nil,
    workspaceId: String? = nil,
    plan: [String]? = nil,
    steps: [ServerSandboxSetupStep]? = nil,
    power: String? = nil,
    error: String? = nil
  ) {
    self.id = id
    self.vendor = vendor
    self.name = name
    self.state = state
    self.profileId = profileId
    self.profileName = profileName
    self.accountId = accountId
    self.deviceId = deviceId
    self.remoteProjectId = remoteProjectId
    self.workspaceId = workspaceId
    self.plan = plan
    self.steps = steps
    self.power = power
    self.error = error
  }
}

private struct SandboxProvidersResponse: Decodable {
  var accounts: [ServerSandboxProvider]
}

private struct SandboxProfilesResponse: Decodable {
  var profiles: [ServerSandboxProfile]
}

private struct SandboxAvailabilityResponse: Decodable {
  var profiles: [ServerSandboxAvailability]
}

extension CodevisorServerClient {
  public func sandboxVendors() async throws -> ServerSandboxVendors {
    try await get("/v1/sandbox-providers")
  }

  public func sandboxProviders() async throws -> [ServerSandboxProvider] {
    let response: SandboxProvidersResponse = try await get("/v1/sandbox-accounts")
    return response.accounts
  }

  public func createSandboxProvider(_ request: ServerSandboxProviderRequest) async throws -> ServerSandboxProvider {
    try await send("/v1/sandbox-accounts", method: "POST", body: request)
  }

  public func updateSandboxProvider(
    id: String,
    _ request: ServerSandboxProviderRequest
  ) async throws -> ServerSandboxProvider {
    try await send("/v1/sandbox-accounts/\(pathComponent(id))", method: "PUT", body: request)
  }

  public func deleteSandboxProvider(id: String) async throws {
    try await sendNoResponse("/v1/sandbox-accounts/\(pathComponent(id))", method: "DELETE")
  }

  public func deleteSandboxProviderAndProfiles(id: String) async throws {
    try await sendNoResponse("/v1/sandbox-accounts/\(pathComponent(id))?cascade=true", method: "DELETE")
  }

  public func sandboxProfiles() async throws -> [ServerSandboxProfile] {
    let response: SandboxProfilesResponse = try await get("/v1/sandbox-profiles")
    return response.profiles
  }

  public func createSandboxProfile(_ request: ServerSandboxProfileRequest) async throws -> ServerSandboxProfile {
    try await send("/v1/sandbox-profiles", method: "POST", body: request)
  }

  public func updateSandboxProfile(
    id: String,
    _ request: ServerSandboxProfileRequest
  ) async throws -> ServerSandboxProfile {
    try await send("/v1/sandbox-profiles/\(pathComponent(id))", method: "PUT", body: request)
  }

  public func deleteSandboxProfile(id: String) async throws {
    try await sendNoResponse("/v1/sandbox-profiles/\(pathComponent(id))", method: "DELETE")
  }

  public func sandboxAvailability() async throws -> [ServerSandboxAvailability] {
    let response: SandboxAvailabilityResponse = try await get("/v1/sandbox-profiles/availability")
    return response.profiles
  }

  public func sandboxes() async throws -> [ServerSandbox] {
    try await get("/v1/sandboxes")
  }

  public func destroySandbox(id: String) async throws {
    try await sendNoResponse("/v1/sandboxes/\(pathComponent(id))", method: "DELETE")
  }

  public func wakeSandbox(id: String) async throws -> ServerSandbox {
    try await send("/v1/sandboxes/\(pathComponent(id))/wake", method: "POST", body: Optional<EmptyBody>.none)
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
